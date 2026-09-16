defmodule Jido.Cluster.Admission do
  @moduledoc """
  Pure slot ledger for one connected capacity scope.

  Pool aliases do not create capacity. Reservations precede activation and remain
  charged during uncertainty. Only the scope authority may apply this ledger;
  host observations or process exit cannot grant capacity or prove retirement.
  """
  alias Jido.Agent.Ref
  alias Jido.Cluster.Deployment.Planner

  defstruct [:scope, hosts: %{}, claims: %{}, requests: %{}, excluded: MapSet.new(), provider_pending: MapSet.new()]
  @type t :: %__MODULE__{}

  @doc "Creates one canonical host inventory, accepting identical pool aliases."
  @spec new(term(), [map()]) :: {:ok, t()} | {:error, term()}
  def new(scope, hosts) when is_list(hosts) do
    unique = hosts |> Enum.map(&normalize_host/1) |> Enum.uniq()

    case {Planner.validate_hosts(unique), valid_allocations?(unique)} do
      {:ok, true} -> {:ok, %__MODULE__{scope: scope, hosts: Map.new(unique, &{&1.node, &1})}}
      _ -> {:error, :conflicting_host_budget}
    end
  end

  def new(_, _), do: {:error, :invalid_inventory}

  defp normalize_host(host) when is_map(host), do: Map.put_new(host, :allocation, "default")
  defp normalize_host(host), do: host

  defp valid_allocations?(hosts) do
    Enum.all?(hosts, fn
      host when is_map(host) ->
        id = Map.get(host, :allocation, "default")
        is_binary(id) and byte_size(id) in 1..128

      _ ->
        false
    end)
  end

  @doc "Reports remaining candidate slots. Uncertain and excluded allocations are unavailable."
  @spec available_hosts(t()) :: [map()]
  def available_hosts(ledger) do
    used = ledger.claims |> Map.values() |> Enum.frequencies_by(& &1.host)
    uncertain = uncertain_hosts(ledger)

    ledger.hosts
    |> Map.values()
    |> Enum.sort_by(& &1.node)
    |> Enum.map(fn host ->
      %{
        host
        | capacity: host.capacity - Map.get(used, host.node, 0),
          available:
            host.available and not MapSet.member?(ledger.excluded, host.node) and
              not MapSet.member?(ledger.provider_pending, host.node) and
              not MapSet.member?(uncertain, host.node)
      }
    end)
  end

  @doc "Reserves complete Ref demand atomically, or returns an error without changing state."
  @spec reserve(t(), String.t(), %{Ref.t() => node()}, String.t()) :: {:ok, t()} | {:error, term()}
  def reserve(ledger, topology, demand, operation) when is_map(demand) do
    binding = {topology, demand}

    case Map.fetch(ledger.requests, operation) do
      {:ok, ^binding} -> {:ok, ledger}
      {:ok, _} -> {:error, :operation_conflict}
      :error -> reserve_new(ledger, topology, demand, operation)
    end
  end

  @doc "Updates one operation's retained claims from confirmed or uncertain outcomes."
  @spec mark(t(), String.t(), :active | :uncertain) :: t()
  def mark(ledger, operation, phase) when phase in [:active, :uncertain] do
    claims =
      Map.new(ledger.claims, fn {key, claim} ->
        {key, if(claim.operation_id == operation, do: %{claim | state: phase}, else: claim)}
      end)

    %{ledger | claims: claims}
  end

  @doc "Releases one deployment only after its caller establishes confirmed cleanup."
  @spec release(t(), String.t(), term()) :: {:ok, t()} | {:error, term()}
  def release(ledger, topology, :confirmed),
    do: {:ok, %{ledger | claims: Map.reject(ledger.claims, fn {_, claim} -> claim.topology_id == topology end)}}

  def release(_, _, _), do: {:error, :unconfirmed_cleanup}

  @doc "Retires exact source claims after confirmed movement cleanup."
  @spec retire(t(), String.t(), %{Ref.t() => node()}, term()) :: {:ok, t()} | {:error, term()}
  def retire(ledger, topology, demand, :confirmed) do
    keys = Enum.map(demand, fn {ref, host} -> {topology, ref, host} end)
    {:ok, %{ledger | claims: Map.drop(ledger.claims, keys)}}
  end

  def retire(_, _, _, _), do: {:error, :unconfirmed_cleanup}

  @doc "Excludes a draining host from new reservation. Existing claims remain charged."
  @spec exclude(t(), node()) :: t()
  def exclude(ledger, host), do: %{ledger | excluded: MapSet.put(ledger.excluded, host)}

  @doc "Re-enables a host after an explicit operator request."
  @spec enable(t(), node()) :: t()
  def enable(ledger, host), do: %{ledger | excluded: MapSet.delete(ledger.excluded, host)}

  @doc "Returns charged claims in stable order for public status and model tests."
  @spec claims(t()) :: [map()]
  def claims(ledger), do: ledger.claims |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

  @doc "Binds reserved claims to a directly observed host incarnation before confirmation."
  @spec bind_host(t(), String.t(), node(), String.t()) :: {:ok, t(), [map()]} | {:error, term()}
  def bind_host(ledger, operation, host, incarnation) do
    selected = Enum.filter(claims(ledger), &(&1.operation_id == operation and &1.host == host))

    if selected != [] and Enum.all?(selected, &(&1.host_incarnation in [nil, incarnation])) do
      selected = Enum.map(selected, &%{&1 | host_incarnation: incarnation})
      updated = Map.merge(ledger.claims, Map.new(selected, &{&1.id, &1}))
      {:ok, %{ledger | claims: updated}, selected}
    else
      {:error, :stale_incarnation}
    end
  end

  @doc "Parks every retained claim for a deployment with unknown cleanup."
  @spec uncertain_deployment(t(), String.t()) :: t()
  def uncertain_deployment(ledger, topology) do
    claims =
      Map.new(ledger.claims, fn {id, claim} ->
        {id, if(claim.topology_id == topology, do: %{claim | state: :uncertain}, else: claim)}
      end)

    %{ledger | claims: claims}
  end

  defp reserve_new(ledger, topology, demand, operation) do
    with :ok <- check_conflicts(ledger, topology, demand),
         :ok <- check_capacity(ledger, demand) do
      additions =
        Map.new(demand, fn {ref, host} ->
          key = {topology, ref, host}

          {key,
           %{
             id: key,
             scope: ledger.scope,
             topology_id: topology,
             ref: ref,
             host: host,
             allocation: Map.get(Map.fetch!(ledger.hosts, host), :allocation, "default"),
             host_incarnation: nil,
             operation_id: operation,
             state: :reserved
           }}
        end)

      {:ok,
       %{
         ledger
         | claims: Map.merge(ledger.claims, additions),
           requests: Map.put(ledger.requests, operation, {topology, demand})
       }}
    end
  end

  defp check_conflicts(ledger, topology, demand) do
    uncertain = Enum.filter(Map.values(ledger.claims), &(&1.state == :uncertain))
    conflicts = Enum.filter(uncertain, &(&1.topology_id == topology or &1.host in Map.values(demand)))
    duplicate = Enum.any?(demand, fn {ref, host} -> Map.has_key?(ledger.claims, {topology, ref, host}) end)

    cond do
      conflicts != [] -> {:error, {:resources_uncertain, Enum.map(conflicts, & &1.id)}}
      duplicate -> {:error, :claim_already_reserved}
      true -> :ok
    end
  end

  defp check_capacity(ledger, demand) do
    required = Enum.frequencies(Map.values(demand))
    hosts = Map.new(available_hosts(ledger), &{&1.node, &1})

    required
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {host, slots}, :ok ->
      capacity_result(check_host(ledger, Map.get(hosts, host), host, slots))
    end)
  end

  defp check_host(ledger, candidate, host, slots) do
    cond do
      MapSet.member?(ledger.excluded, host) -> {:error, {:host_excluded, host}}
      candidate == nil -> {:error, {:unknown_host, host}}
      not candidate.available -> {:error, {:host_unavailable, host}}
      candidate.capacity < slots -> {:error, {:no_capacity, host}}
      true -> :ok
    end
  end

  defp capacity_result(:ok), do: {:cont, :ok}
  defp capacity_result(error), do: {:halt, error}

  defp uncertain_hosts(ledger),
    do: ledger.claims |> Map.values() |> Enum.filter(&(&1.state == :uncertain)) |> MapSet.new(& &1.host)
end
