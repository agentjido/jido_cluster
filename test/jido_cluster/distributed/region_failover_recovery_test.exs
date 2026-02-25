defmodule JidoCluster.Distributed.RegionFailoverRecoveryTest do
  use ExUnitCluster.Case, async: false

  import JidoCluster.Test.Eventually

  alias JidoCluster.Topology

  test "key remains serviceable after owner node is terminated", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])
    await_full_mesh(cluster, [n1, n2])

    manager = unique_manager(:region_failover)

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: {JidoCluster.Storage.Mnesia, table: unique_table(:region_failover), ram_copies: [n1, n2]},
      rebalance: true,
      rebalance_interval_ms: 120_000,
      max_migrations_per_tick: 1
    ]

    start_managers(cluster, [n1, n2], opts)

    key = pick_key_owned_by(manager, [n1, n2], n2)
    signal = Jido.Signal.new!("inc", %{}, source: "/test/failover")

    assert {:ok, _agent} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [manager, key, signal, 5_000])

    assert {:ok, pid_before} = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :lookup, [manager, key])
    assert node(pid_before) == n2

    assert :ok = ExUnitCluster.stop_node(cluster, n2)

    eventually(fn ->
      ExUnitCluster.call(cluster, n1, Topology, :connected_nodes, []) == [n1]
    end)

    assert {:ok, recovered_pid} = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :get, [manager, key, []])
    assert node(recovered_pid) == n1

    assert {:ok, _agent} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [manager, key, signal, 5_000])

    assert %{total: 1} = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :stats, [manager])
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

  defp pick_key_owned_by(manager, nodes, owner) do
    nodes = Enum.sort(nodes)

    Enum.find_value(1..500, fn index ->
      key = "region-failover-#{index}"

      case Topology.owner_node(manager, key, nodes) do
        ^owner -> key
        _other -> nil
      end
    end) ||
      raise("Failed to find key for owner #{inspect(owner)}")
  end

  defp unique_manager(prefix) do
    :"manager_#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp unique_table(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
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
