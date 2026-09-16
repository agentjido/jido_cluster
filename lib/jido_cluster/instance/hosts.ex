defmodule Jido.Cluster.Instance.Hosts do
  @moduledoc false
  alias Jido.Cluster.{Drain, HostRuntime, Instance}
  alias Jido.Cluster.Instance.Service

  @doc "Confirms the reserved demand on every selected host before core starts."
  @spec confirm(Instance.Config.t(), Jido.Topology.Instance.t(), pid(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def confirm(config, topology, owner, placements, operation) do
    with {:ok, expected} <- expected(config, topology) do
      result =
        placements
        |> Map.values()
        |> Enum.uniq()
        |> Enum.reduce_while({:ok, []}, fn worker, {:ok, hosts} ->
          confirm_result(confirm_one(config, owner, worker, expected, operation), hosts)
        end)

      case result do
        {:ok, hosts} -> {:ok, %{owner: owner, scope: {config.namespace, config.scope}, hosts: hosts}}
        error -> error
      end
    end
  catch
    :exit, reason -> {:error, {:host_confirmation_uncertain, reason}}
  end

  @doc "Builds the compatibility requirements for direct host confirmation or recovery."
  @spec expected(Instance.Config.t(), Jido.Topology.Instance.t()) :: {:ok, keyword()} | {:error, term()}
  def expected(config, topology) do
    with {:ok, local} <- HostRuntime.probe(HostRuntime.name(config.jido), []) do
      {:ok,
       [
         namespace: config.namespace,
         protocol: 1,
         release: local.release,
         persistence_identity: local.persistence_identity,
         modules: topology.plan.agents |> Map.values() |> Enum.map(& &1.module) |> Enum.uniq()
       ]}
    end
  end

  @doc "Confirms every retained transition claim before recovery starts core."
  @spec confirm_retained(Instance.Config.t(), Jido.Topology.Instance.t(), pid()) :: {:ok, map()} | {:error, term()}
  def confirm_retained(config, topology, owner) do
    guard = %{owner: owner, scope: {config.namespace, config.scope}, hosts: []}

    Service.call(owner, :claims)
    |> Enum.filter(&(&1.topology_id == topology.id))
    |> Enum.group_by(& &1.operation_id)
    |> Enum.reduce_while({:ok, guard}, fn {operation, claims}, {:ok, guard} ->
      placements = Map.new(claims, &{&1.ref, &1.host})

      case confirm(config, topology, owner, placements, operation) do
        {:ok, confirmed} -> {:cont, {:ok, %{guard | hosts: guard.hosts ++ confirmed.hosts}}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Checks the accepted host incarnations and exact confirmed claims."
  @spec verify(map() | nil) :: :ok | {:error, term()}
  def verify(nil), do: :ok

  def verify(guard) do
    Enum.reduce_while(guard.hosts, :ok, fn host, :ok ->
      result = HostRuntime.verify(host.server, guard.owner, guard.scope, host.incarnation, host.ids)
      reduce_result(result)
    end)
  catch
    :exit, reason -> {:error, {:host_guard_uncertain, reason}}
  end

  @doc "Builds a guard from the current ledger claims for one accepted placement."
  @spec guard(Instance.Config.t(), pid(), Jido.Topology.Instance.t(), map()) :: map()
  def guard(config, owner, topology, placements) do
    demand = Drain.demand(topology, config.namespace, placements)
    claims = Service.call(owner, :claims)

    hosts =
      claims
      |> Enum.filter(&(&1.topology_id == topology.id and Map.get(demand, &1.ref) == &1.host))
      |> Enum.group_by(&{&1.host, &1.host_incarnation})
      |> Enum.map(fn {{host, incarnation}, group} ->
        %{server: {HostRuntime.name(config.jido), host}, incarnation: incarnation, ids: Enum.map(group, & &1.id)}
      end)

    %{owner: owner, scope: {config.namespace, config.scope}, hosts: hosts}
  end

  @doc "Releases host confirmations after core cleanup completes."
  @spec release(Instance.Config.t(), pid(), [map()]) :: :ok | {:error, term()}
  def release(config, owner, claims) do
    claims
    |> Enum.reject(&is_nil(&1.host_incarnation))
    |> Enum.group_by(&{&1.host, &1.host_incarnation})
    |> Enum.reduce_while(:ok, fn {{host, incarnation}, group}, :ok ->
      result =
        HostRuntime.release(
          {HostRuntime.name(config.jido), host},
          owner,
          {config.namespace, config.scope},
          incarnation,
          Enum.map(group, & &1.id),
          :confirmed
        )

      reduce_result(result)
    end)
  catch
    :exit, reason -> {:error, {:host_release_uncertain, reason}}
  end

  defp confirm_one(config, owner, worker, expected, operation) do
    host = {HostRuntime.name(config.jido), worker}
    candidate = Enum.find(config.hosts, &(&1.node == worker))
    capacity = candidate.capacity
    allocation = Map.get(candidate, :allocation, "default")

    with {:ok, info} <- stage(:probe, HostRuntime.probe(host, expected, config.timeout)),
         :ok <-
           stage(
             :registration,
             register(config, owner, candidate, host, info.incarnation, allocation)
           ),
         {:ok, claims} <-
           stage(:reservation, Service.call(owner, {:confirm_host, operation, worker, info.incarnation})),
         :ok <-
           stage(
             :confirmation,
             HostRuntime.confirm(host, owner, {config.namespace, config.scope}, info.incarnation, capacity, claims)
           ) do
      {:ok, %{server: host, incarnation: info.incarnation, ids: Enum.map(claims, & &1.id)}}
    else
      {:error, {stage, reason}} ->
        {:error, {:host_rejected, %{host: worker, allocation: allocation, stage: stage, reason: reason}}}
    end
  catch
    :exit, reason -> {:error, {:host_confirmation_uncertain, %{host: worker, reason: reason}}}
  end

  defp register(config, owner, candidate, host, incarnation, allocation) do
    scope = {config.namespace, config.scope}

    case HostRuntime.register(host, owner, scope, incarnation, allocation) do
      {:error, :reconciliation_required} ->
        reconcile_empty(owner, candidate, host, scope, incarnation, allocation)

      result ->
        result
    end
  end

  defp reconcile_empty(owner, candidate, host, scope, incarnation, allocation) do
    # A stopped deployment can leave an empty guard attached to a lost owner.
    # Bound or uncertain ledger claims still require full recovery, even when
    # the host currently reports no claims. Reconcile checks the empty set again.
    with %{incarnation: ^incarnation, allocations: allocations} <- HostRuntime.status(host),
         %{claims: [], scope: retained_scope, capacity: capacity} <- Map.get(allocations, allocation),
         true <- retained_scope in [nil, scope] and capacity in [nil, candidate.capacity],
         true <- only_unconfirmed_reservations?(owner, candidate.node) do
      HostRuntime.reconcile(host, owner, scope, incarnation, [], allocation)
    else
      _ -> {:error, :reconciliation_required}
    end
  end

  defp only_unconfirmed_reservations?(owner, worker) do
    owner
    |> Service.call(:claims)
    |> Enum.filter(&(&1.host == worker))
    |> Enum.all?(&(&1.state == :reserved and is_nil(&1.host_incarnation)))
  end

  defp stage(name, {:error, reason}), do: {:error, {name, reason}}
  defp stage(_name, result), do: result

  defp confirm_result({:ok, host}, hosts), do: {:cont, {:ok, [host | hosts]}}
  defp confirm_result(error, _hosts), do: {:halt, error}
  defp reduce_result(:ok), do: {:cont, :ok}
  defp reduce_result(error), do: {:halt, error}
end
