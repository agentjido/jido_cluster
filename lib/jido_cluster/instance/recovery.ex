defmodule Jido.Cluster.Instance.Recovery do
  @moduledoc false
  alias Jido.Cluster.{Activation, Deployment, Drain, HostRuntime, Instance}
  alias Jido.Cluster.Instance.{Hosts, Service, Work}

  @doc "Settles prior owners and host claims before any admitted replacement starts."
  @spec run(Instance.Config.t(), pid(), [String.t()]) :: :ok
  def run(config, owner, ids) do
    ready = Enum.filter(ids, &prepare(config, owner, &1))

    Enum.each(ready, fn id ->
      result =
        case Service.call(owner, {:recovery_candidate, id}) do
          {:ok, d} -> deploy(config, owner, d)
          {:error, reason} -> %{phase: :uncertain, reason: reason}
        end

      Service.call(owner, {:recovery_result, id, result})
    end)

    :ok
  end

  defp deploy(config, owner, d) do
    case Work.deploy(config, d, owner, d.activation.id) do
      %{phase: :completed} = result ->
        demand = Drain.demand(d.instance, config.namespace, d.selected)

        retired =
          Enum.filter(Service.call(owner, :claims), fn claim ->
            claim.topology_id == d.instance.id and Map.get(demand, claim.ref) != claim.host
          end)

        case Hosts.release(config, owner, retired) do
          :ok -> result
          {:error, reason} -> %{result | phase: :uncertain, reason: reason}
        end

      result ->
        result
    end
  end

  defp prepare(config, owner, id) do
    result =
      with {:ok, d, claims} <- Service.call(owner, {:recovery_target, id}),
           :ok <- cleanup(config, d),
           :ok <- restore_placement(config, d),
           :ok <- release_hosts(config, owner, d, claims),
           {:ok, prepared} <- Service.call(owner, {:recovery_prepare, id, d.activation.id}) do
        {:ok, prepared.desired == :running}
      end

    case result do
      {:ok, running} ->
        running

      {:error, reason} ->
        Service.call(owner, {:recovery_result, id, %{phase: :uncertain, reason: reason}})
        false
    end
  catch
    :exit, reason ->
      Service.call(owner, {:recovery_result, id, %{phase: :uncertain, reason: {:recovery_exit, reason}}})
      false
  end

  defp restore_placement(_config, %{desired: :stopped}), do: :ok
  defp restore_placement(_config, %{initial_selected: selected, selected: selected}), do: :ok

  defp restore_placement(config, _deployment) do
    case Jido.Persistence.resolve_config(:inherit, config.jido) do
      {:ok, nil} -> {:error, :placement_restore_requires_persistence}
      {:ok, {_adapter, _options}} -> :ok
      error -> error
    end
  end

  defp cleanup(config, d) do
    runner = Deployment.whereis(config.jido, d.instance.id)

    result =
      case Activation.cleanup(d.activation) do
        :ok ->
          :ok

        {:error, reason} when reason in [:activation_missing, :activation_changed] ->
          Activation.unstarted(d.activation)

        error ->
          error
      end

    with :ok <- result, do: await_runner(runner, config.timeout)
  end

  defp await_runner(nil, _), do: :ok

  defp await_runner(pid, timeout) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :prior_runner_still_present}
    end
  end

  defp release_hosts(config, owner, d, claims) do
    hosts = (Enum.filter(claims, &(&1.topology_id == d.instance.id)) |> Enum.map(& &1.host)) ++ Map.values(d.selected)

    Enum.reduce_while(Enum.uniq(hosts), :ok, fn node, :ok ->
      case release_host(config, owner, d, claims, node) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp release_host(config, owner, d, claims, node) do
    host = {HostRuntime.name(config.jido), node}
    candidate = Enum.find(config.hosts, &(&1.node == node))
    scope = {config.namespace, config.scope}

    with {:ok, expected} <- Hosts.expected(config, d.instance),
         {:ok, info} <- HostRuntime.probe(host, expected, config.timeout),
         status = HostRuntime.status(host),
         {:ok, partition} <- partition(status, candidate, scope),
         :ok <- matching_claims(partition.claims, claims),
         :ok <- Service.call(owner, {:recovery_host, d.instance.id, node, info.incarnation}),
         :ok <- HostRuntime.reconcile(host, owner, scope, info.incarnation, partition.claims, candidate.allocation) do
      ids = for claim <- partition.claims, claim.topology_id == d.instance.id, do: claim.id
      HostRuntime.release(host, owner, scope, info.incarnation, ids, :confirmed)
    end
  end

  defp partition(status, candidate, scope) do
    case Map.get(status.allocations, candidate.allocation) do
      %{scope: recorded, capacity: capacity} = partition
      when recorded in [nil, scope] and capacity in [nil, candidate.capacity] ->
        {:ok, partition}

      _ ->
        {:error, :host_allocation_changed}
    end
  end

  defp matching_claims(actual, claims) do
    expected = Map.new(claims, &{&1.id, Map.delete(&1, :state)})

    if Enum.all?(actual, &(Map.get(expected, &1.id) == Map.delete(&1, :state))),
      do: :ok,
      else: {:error, :host_claim_mismatch}
  end
end
