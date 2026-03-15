defmodule JidoCluster.Distributed.EphemeralRuntimeScenariosTest do
  use ExUnitCluster.Case, async: false

  import JidoCluster.Test.Eventually

  alias Jido.Cluster.InstanceManager
  alias Jido.Cluster.Topology
  alias JidoCluster.KeyRuntime

  @timeout 10_000

  test "single-node manager provides a stable local singleton lifecycle", %{cluster: cluster} do
    [n1] = start_nodes(cluster, 1)
    ensure_apps(cluster, [n1])

    manager = unique_manager(:scenario_single_node)
    start_managers(cluster, [n1], ephemeral_opts(manager, rebalance: false))

    key = "scenario-single-node-1"
    signal = increment_signal()

    assert {:ok, pid} = ExUnitCluster.call(cluster, n1, InstanceManager, :get, [manager, key, []])
    assert node(pid) == n1

    assert n1 == ExUnitCluster.call(cluster, n1, InstanceManager, :owner_node, [manager, key])

    assert {:ok, first} = ExUnitCluster.call(cluster, n1, InstanceManager, :call, [manager, key, signal, @timeout])
    assert first.state.count == 1

    assert :ok = ExUnitCluster.call(cluster, n1, InstanceManager, :cast, [manager, key, signal])

    eventually(fn ->
      assert {:ok, state} = ExUnitCluster.call(cluster, n1, Jido.AgentServer, :state, [pid])
      state.agent.state.count == 2
    end)

    assert %{total: 1, by_node: %{^n1 => 1}} = ExUnitCluster.call(cluster, n1, InstanceManager, :stats, [manager])
  end

  test "two nodes route through one logical singleton from either side", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])
    await_full_mesh(cluster, [n1, n2])

    manager = unique_manager(:scenario_mirrored_access)
    start_managers(cluster, [n1, n2], ephemeral_opts(manager))

    key = "scenario-mirrored-1"
    signal = increment_signal()

    assert {:ok, pid_1} = ExUnitCluster.call(cluster, n1, InstanceManager, :get, [manager, key, []])
    assert {:ok, pid_2} = ExUnitCluster.call(cluster, n2, InstanceManager, :get, [manager, key, []])
    assert pid_1 == pid_2

    owner = ExUnitCluster.call(cluster, n1, InstanceManager, :owner_node, [manager, key])
    assert owner in [n1, n2]
    assert node(pid_1) == owner

    assert {:ok, first} = ExUnitCluster.call(cluster, n2, InstanceManager, :call, [manager, key, signal, @timeout])
    assert first.state.count == 1

    assert :ok = ExUnitCluster.call(cluster, n1, InstanceManager, :cast, [manager, key, signal])

    eventually(fn ->
      assert {:ok, state} = ExUnitCluster.call(cluster, owner, Jido.AgentServer, :state, [pid_1])
      state.agent.state.count == 2
    end)

    {primary_summary, standby_summary} =
      eventually(fn ->
        s1 = ExUnitCluster.call(cluster, n1, KeyRuntime, :local_summary, [manager, key])
        s2 = ExUnitCluster.call(cluster, n2, KeyRuntime, :local_summary, [manager, key])

        case {s1, s2} do
          {%{role: :primary} = primary, %{role: :standby} = standby} -> {primary, standby}
          {%{role: :standby} = standby, %{role: :primary} = primary} -> {primary, standby}
          _ -> false
        end
      end)

    assert primary_summary.primary == owner
    assert standby_summary.primary == owner
    assert primary_summary.seq == 2
    assert standby_summary.seq == 2
  end

  test "joining a second node rebalances ownership without resetting agent state", %{cluster: cluster} do
    [n1] = start_nodes(cluster, 1)
    ensure_apps(cluster, [n1])

    manager = unique_manager(:scenario_rebalance_join)
    opts = ephemeral_opts(manager)
    start_managers(cluster, [n1], opts)

    n2 = ExUnitCluster.start_node(cluster)
    ensure_apps(cluster, [n2])
    start_managers(cluster, [n2], opts)
    await_full_mesh(cluster, [n1, n2])

    key = pick_key_owned_by(manager, [n1, n2], n2)
    signal = increment_signal()

    assert {:ok, first} = ExUnitCluster.call(cluster, n1, InstanceManager, :call, [manager, key, signal, @timeout])
    assert first.state.count == 1

    assert :ok = ExUnitCluster.call(cluster, n1, JidoCluster.Rebalancer, :trigger_sync, [manager, @timeout])

    eventually(fn ->
      ExUnitCluster.call(cluster, n1, InstanceManager, :owner_node, [manager, key]) == n2
    end)

    assert {:ok, pid_after} = ExUnitCluster.call(cluster, n1, InstanceManager, :get, [manager, key, []])
    assert node(pid_after) == n2

    assert {:ok, second} = ExUnitCluster.call(cluster, n1, InstanceManager, :call, [manager, key, signal, @timeout])
    assert second.state.count == 2
  end

  test "latest acknowledged state survives primary loss and failover", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])
    await_full_mesh(cluster, [n1, n2])

    manager = unique_manager(:scenario_failover)
    start_managers(cluster, [n1, n2], ephemeral_opts(manager))

    key = pick_key_owned_by(manager, [n1, n2], n1)
    signal = increment_signal()

    assert {:ok, first} = ExUnitCluster.call(cluster, n2, InstanceManager, :call, [manager, key, signal, @timeout])
    assert first.state.count == 1

    assert {:ok, second} = ExUnitCluster.call(cluster, n1, InstanceManager, :call, [manager, key, signal, @timeout])
    assert second.state.count == 2

    assert :ok = ExUnitCluster.stop_node(cluster, n1)

    eventually(fn ->
      ExUnitCluster.call(cluster, n2, Topology, :connected_nodes, []) == [n2]
    end)

    assert {:ok, promoted_pid} = ExUnitCluster.call(cluster, n2, InstanceManager, :get, [manager, key, []])
    assert node(promoted_pid) == n2

    assert {:ok, promoted_state} = ExUnitCluster.call(cluster, n2, Jido.AgentServer, :state, [promoted_pid])
    assert promoted_state.agent.state.count == 2

    assert {:ok, third} = ExUnitCluster.call(cluster, n2, InstanceManager, :call, [manager, key, signal, @timeout])
    assert third.state.count == 3
  end

  test "multi-key fleet distributes primary ownership across both nodes", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])
    await_full_mesh(cluster, [n1, n2])

    manager = unique_manager(:scenario_fleet)
    start_managers(cluster, [n1, n2], ephemeral_opts(manager, rebalance: false))

    keys_for_n1 = pick_keys_owned_by(manager, [n1, n2], n1, 3)
    keys_for_n2 = pick_keys_owned_by(manager, [n1, n2], n2, 3)
    signal = increment_signal()

    Enum.each(keys_for_n1 ++ keys_for_n2, fn key ->
      caller = if rem(:erlang.phash2(key), 2) == 0, do: n1, else: n2

      assert {:ok, agent} =
               ExUnitCluster.call(cluster, caller, InstanceManager, :call, [manager, key, signal, @timeout])

      assert agent.state.count == 1
    end)

    stats =
      eventually(fn ->
        stats = ExUnitCluster.call(cluster, n1, InstanceManager, :stats, [manager])

        if stats.total == 6 and Map.get(stats.by_node, n1, 0) >= 1 and Map.get(stats.by_node, n2, 0) >= 1 do
          stats
        else
          false
        end
      end)

    assert %{total: 6} = stats

    Enum.each(keys_for_n1, fn key ->
      assert n1 == ExUnitCluster.call(cluster, n2, InstanceManager, :owner_node, [manager, key])
    end)

    Enum.each(keys_for_n2, fn key ->
      assert n2 == ExUnitCluster.call(cluster, n1, InstanceManager, :owner_node, [manager, key])
    end)
  end

  defp ephemeral_opts(manager, overrides \\ []) do
    base = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: nil,
      rebalance: true,
      rebalance_interval_ms: 120_000,
      max_migrations_per_tick: 1,
      min_quorum_nodes: 1,
      partition_policy: :soft_owner,
      handoff_mode: :live_transfer,
      coordination_backend: :connected_beam,
      replication: %{replicas: 1, mode: :sync, promotion_timeout_ms: 750}
    ]

    Keyword.merge(base, overrides)
  end

  defp increment_signal do
    Jido.Signal.new!("inc", %{}, source: "/test/scenario")
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
      case ExUnitCluster.call(cluster, node, InstanceManager, :start, [opts]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        other -> raise("Failed to start manager on node #{inspect(node)}: #{inspect(other)}")
      end
    end)
  end

  defp unique_manager(prefix) do
    :"manager_#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp pick_key_owned_by(manager, nodes, owner) do
    nodes = Enum.sort(nodes)

    Enum.find_value(1..500, fn index ->
      key = "scenario-key-#{index}"
      if Topology.owner_node(manager, key, nodes) == owner, do: key, else: nil
    end) || raise("Failed to find key for owner #{inspect(owner)}")
  end

  defp pick_keys_owned_by(manager, nodes, owner, count) do
    nodes = Enum.sort(nodes)

    1..5_000
    |> Stream.map(&"fleet-key-#{&1}")
    |> Stream.filter(&(Topology.owner_node(manager, &1, nodes) == owner))
    |> Enum.take(count)
  end

  defp await_full_mesh(cluster, nodes) do
    expected = Enum.sort(nodes)

    eventually(
      fn ->
        Enum.all?(nodes, fn node ->
          ExUnitCluster.call(cluster, node, Topology, :connected_nodes, []) == expected
        end)
      end,
      timeout: 5_000
    )
  end

  defp assert_app_started(:ok), do: :ok
  defp assert_app_started({:ok, apps}) when is_list(apps), do: :ok
  defp assert_app_started(other), do: raise("Failed to start app on cluster node: #{inspect(other)}")
end
