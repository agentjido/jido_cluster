defmodule JidoCluster.PartitionMonitor do
  @moduledoc """
  Manager-scoped quorum monitor for connected-BEAM deployments.

  When the local node loses quorum under `partition_policy: :freeze`, the
  monitor stops all locally owned keyed agents so they hibernate through the
  configured storage backend and the minority side stops serving work.
  """

  use GenServer

  alias JidoCluster.Internal.InstanceManagerConfig
  alias JidoCluster.{KeyRuntime, Rebalancer, Topology}

  @type state :: %{
          manager: term(),
          partition_policy: atom(),
          min_quorum_nodes: pos_integer(),
          coordination_backend: term(),
          quorum_met?: boolean()
        }

  @doc "Child specification for a manager-scoped partition monitor."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    manager = Keyword.fetch!(opts, :manager)

    %{
      id: {__MODULE__, manager},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    manager = Keyword.fetch!(opts, :manager)
    GenServer.start_link(__MODULE__, opts, name: name(manager))
  end

  @doc false
  @spec name(term()) :: atom()
  def name(manager), do: Module.concat(__MODULE__, "#{manager}")

  @impl true
  def init(opts) do
    :ok = :net_kernel.monitor_nodes(true)

    state = %{
      manager: Keyword.fetch!(opts, :manager),
      partition_policy: Keyword.get(opts, :partition_policy, :freeze),
      min_quorum_nodes: Keyword.get(opts, :min_quorum_nodes, 1),
      coordination_backend: Keyword.get(opts, :coordination_backend, :connected_beam),
      quorum_met?: true
    }

    send(self(), :evaluate_topology)

    {:ok, state}
  end

  @impl true
  def handle_info({event, _node}, state) when event in [:nodeup, :nodedown] do
    {:noreply, evaluate_topology(state)}
  end

  def handle_info(:evaluate_topology, state) do
    {:noreply, evaluate_topology(state)}
  end

  defp evaluate_topology(%{coordination_backend: :connected_beam} = state) do
    nodes = Topology.connected_nodes()
    quorum_met? = Topology.quorum_met?(state.min_quorum_nodes, nodes)

    cond do
      state.partition_policy != :freeze ->
        %{state | quorum_met?: quorum_met?}

      state.quorum_met? and not quorum_met? ->
        stopped_count = freeze_local_keys(state.manager)
        emit(:freeze, %{count: stopped_count}, metadata(state, nodes))
        %{state | quorum_met?: false}

      not state.quorum_met? and quorum_met? ->
        emit(:unfreeze, %{count: 1}, metadata(state, nodes))
        maybe_trigger_rebalance(state.manager)
        %{state | quorum_met?: true}

      true ->
        %{state | quorum_met?: quorum_met?}
    end
  end

  defp evaluate_topology(state), do: state

  defp freeze_local_keys(manager) do
    if live_transfer?(manager) do
      manager
      |> KeyRuntime.local_keys()
      |> Enum.count(fn key ->
        KeyRuntime.stop_local(manager, key) == :ok
      end)
    else
      manager
      |> Jido.Agent.InstanceManager.stats()
      |> Map.get(:keys, [])
      |> Enum.count(fn key ->
        Jido.Agent.InstanceManager.stop(manager, key) == :ok
      end)
    end
  end

  defp live_transfer?(manager) do
    case InstanceManagerConfig.fetch_cluster(manager) do
      {:ok, %{handoff_mode: :live_transfer}} -> true
      _ -> false
    end
  end

  defp maybe_trigger_rebalance(manager) do
    case Process.whereis(Rebalancer.name(manager)) do
      nil -> :ok
      _pid -> Rebalancer.trigger(manager)
    end
  end

  defp metadata(state, nodes) do
    %{
      manager: state.manager,
      partition_policy: state.partition_policy,
      min_quorum_nodes: state.min_quorum_nodes,
      nodes: nodes
    }
  end

  defp emit(stage, measurements, metadata) do
    :telemetry.execute([:jido_cluster, :partition, stage], measurements, metadata)
  end
end
