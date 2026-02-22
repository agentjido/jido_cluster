defmodule JidoCluster.Distributed.InstanceManagerClusterTest do
  use ExUnitCluster.Case, async: false

  import JidoCluster.Test.Eventually

  alias JidoCluster.Topology

  @doc false
  def attach_migration_counter(counter_id, stage) do
    event = [:jido_cluster, :rebalancer, :migration, stage]
    handler_id = {__MODULE__, counter_id, stage}

    :persistent_term.put({:migration_counter, counter_id, stage}, 0)

    :telemetry.attach(
      handler_id,
      event,
      &__MODULE__.increment_migration_counter/4,
      {counter_id, stage}
    )

    :ok
  end

  @doc false
  def increment_migration_counter(_event, _measurements, _metadata, {id, stage_name}) do
    key = {:migration_counter, id, stage_name}
    current = :persistent_term.get(key, 0)
    :persistent_term.put(key, current + 1)
    :ok
  end

  @doc false
  def read_migration_counter(counter_id, stage) do
    :persistent_term.get({:migration_counter, counter_id, stage}, 0)
  end

  @doc false
  def clear_migration_counter(counter_id, stage) do
    :persistent_term.erase({:migration_counter, counter_id, stage})
    :telemetry.detach({__MODULE__, counter_id, stage})
    :ok
  end

  test "singleton race across nodes returns one live pid", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])

    manager = unique_manager(:race)

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: {JidoCluster.Storage.ETS, table: unique_table(:race_ets)},
      rebalance: false
    ]

    start_managers(cluster, [n1, n2], opts)

    key = "agent-race-1"

    t1 = Task.async(fn -> ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :get, [manager, key, []]) end)
    t2 = Task.async(fn -> ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :get, [manager, key, []]) end)

    assert {:ok, pid1} = Task.await(t1, 10_000)
    assert {:ok, pid2} = Task.await(t2, 10_000)
    assert pid1 == pid2

    stats = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :stats, [manager])
    assert %{total: 1} = stats
  end

  test "cross-node call and cast", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])

    manager = unique_manager(:calls)

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: {JidoCluster.Storage.ETS, table: unique_table(:calls_ets)},
      rebalance: false
    ]

    start_managers(cluster, [n1, n2], opts)

    signal = Jido.Signal.new!("inc", %{}, source: "/test")
    key = "agent-calls-1"

    assert {:ok, agent1} =
             ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :call, [manager, key, signal, 5_000])

    assert agent1.state.count == 1

    assert :ok = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :cast, [manager, key, signal])

    eventually(fn ->
      {:ok, pid} = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :lookup, [manager, key])
      {:ok, state} = ExUnitCluster.call(cluster, n1, Jido.AgentServer, :state, [pid])
      state.agent.state.count == 2
    end)
  end

  test "rebalancer skips migration for ETS and emits skipped telemetry", %{cluster: cluster} do
    [n1] = start_nodes(cluster, 1)
    ensure_apps(cluster, [n1])

    manager = unique_manager(:skip)

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: {JidoCluster.Storage.ETS, table: unique_table(:skip_ets)},
      rebalance: true,
      rebalance_interval_ms: 120_000,
      max_migrations_per_tick: 1
    ]

    start_managers(cluster, [n1], opts)

    pre_join_keys =
      for i <- 1..30 do
        key = "prejoin-#{i}"
        assert {:ok, _pid} = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :get, [manager, key, []])
        key
      end

    n2 = ExUnitCluster.start_node(cluster)
    ensure_apps(cluster, [n2])
    start_managers(cluster, [n2], opts)
    await_full_mesh(cluster, [n1, n2])

    nodes = Enum.sort([n1, n2])

    key =
      Enum.find(pre_join_keys, fn k ->
        Topology.owner_node(manager, k, nodes) == n2
      end)

    assert is_binary(key)

    leader = hd(nodes)
    counter_id = unique_counter_id(:skip)

    assert :ok = ExUnitCluster.call(cluster, leader, __MODULE__, :attach_migration_counter, [counter_id, :skipped])

    assert :ok = ExUnitCluster.call(cluster, leader, JidoCluster.Rebalancer, :trigger_sync, [manager, 10_000])

    eventually(fn ->
      {:ok, pid} = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :lookup, [manager, key])
      node(pid) == n1
    end)

    assert ExUnitCluster.call(cluster, leader, __MODULE__, :read_migration_counter, [counter_id, :skipped]) >= 1
    assert :ok = ExUnitCluster.call(cluster, leader, __MODULE__, :clear_migration_counter, [counter_id, :skipped])
  end

  test "rebalancer migrates one key per tick for shared backend", %{cluster: cluster} do
    [n1] = start_nodes(cluster, 1)
    ensure_apps(cluster, [n1])

    manager = unique_manager(:migrate)

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: {JidoCluster.Storage.Mnesia, table: unique_table(:migrate_mnesia)},
      rebalance: true,
      rebalance_interval_ms: 120_000,
      max_migrations_per_tick: 1
    ]

    start_managers(cluster, [n1], opts)

    pre_join_keys =
      for i <- 1..40 do
        key = "move-#{i}"
        assert {:ok, _pid} = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :get, [manager, key, []])
        key
      end

    n2 = ExUnitCluster.start_node(cluster)
    ensure_apps(cluster, [n2])
    start_managers(cluster, [n2], opts)
    await_full_mesh(cluster, [n1, n2])

    nodes = Enum.sort([n1, n2])

    candidate_keys =
      Enum.filter(pre_join_keys, fn k ->
        Topology.owner_node(manager, k, nodes) == n2
      end)

    assert length(candidate_keys) >= 2

    leader = hd(nodes)
    counter_id = unique_counter_id(:migrate)

    assert :ok = ExUnitCluster.call(cluster, leader, __MODULE__, :attach_migration_counter, [counter_id, :success])

    assert :ok = ExUnitCluster.call(cluster, leader, JidoCluster.Rebalancer, :trigger_sync, [manager, 10_000])

    eventually(fn ->
      moved_count =
        candidate_keys
        |> Enum.take(2)
        |> Enum.count(fn key ->
          case ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :lookup, [manager, key]) do
            {:ok, pid} -> node(pid) == n2
            _ -> false
          end
        end)

      moved_count == 1
    end)

    assert ExUnitCluster.call(cluster, leader, __MODULE__, :read_migration_counter, [counter_id, :success]) >= 1
    assert :ok = ExUnitCluster.call(cluster, leader, __MODULE__, :clear_migration_counter, [counter_id, :success])
  end

  defp ensure_apps(cluster, nodes) do
    Enum.each(nodes, fn node ->
      assert_app_started(ExUnitCluster.call(cluster, node, Application, :ensure_all_started, [:jido]))
      assert_app_started(ExUnitCluster.call(cluster, node, Application, :ensure_all_started, [:jido_cluster]))
    end)
  end

  defp start_nodes(cluster, count) do
    for _ <- 1..count do
      ExUnitCluster.start_node(cluster)
    end
  end

  defp start_managers(cluster, nodes, opts) do
    Enum.each(nodes, fn node ->
      case ExUnitCluster.call(cluster, node, JidoCluster.InstanceManager, :start, [opts]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        other -> raise("Failed to start manager on node #{inspect(node)}: #{inspect(other)}")
      end
    end)
  end

  defp unique_manager(prefix) do
    :"manager_#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp unique_table(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp unique_counter_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp await_full_mesh(cluster, nodes) do
    expected = Enum.sort(nodes)

    eventually(fn ->
      Enum.all?(nodes, fn node ->
        ExUnitCluster.call(cluster, node, Topology, :connected_nodes, []) == expected
      end)
    end)
  end

  defp assert_app_started(:ok), do: :ok
  defp assert_app_started({:ok, apps}) when is_list(apps), do: :ok
  defp assert_app_started(other), do: raise("Failed to start app on cluster node: #{inspect(other)}")
end
