defmodule JidoCluster.Distributed.BedrockAcceptanceTest do
  use ExUnitCluster.Case, async: false
  use JidoCluster.Test.RealBedrockClusterCase

  import JidoCluster.Test.Eventually

  alias JidoCluster.Topology

  @moduletag :real_bedrock
  @moduletag timeout: 60_000

  test "rebalancer hands off a singleton through real Bedrock storage", %{
    cluster: cluster,
    tmp_dir: tmp_dir,
    bedrock_prefix: bedrock_prefix
  } do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1])
    ensure_apps(cluster, [n2])
    write_descriptor!(tmp_dir, [n1])
    assert :ok = boot_server_node!(cluster, n1, tmp_dir)
    assert :ok = boot_client_node!(cluster, n2, tmp_dir)

    manager = unique_manager(:bedrock_handoff)
    key = handoff_key(manager, Enum.sort([n1, n2]), n2)
    signal = Jido.Signal.new!("inc", %{}, source: "/test")

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: {JidoCluster.Storage.Bedrock, storage_opts(bedrock_prefix)},
      rebalance: true,
      rebalance_interval_ms: 120_000,
      max_migrations_per_tick: 1,
      min_quorum_nodes: 1,
      partition_policy: :freeze
    ]

    start_managers(cluster, [n1], opts)

    assert {:ok, first} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert first.state.count == 1

    start_managers(cluster, [n2], opts)
    await_full_mesh(cluster, [n1, n2])

    leader = Topology.leader_node(Enum.sort([n1, n2]))
    assert :ok = ExUnitCluster.call(cluster, leader, JidoCluster.Rebalancer, :trigger_sync, [manager, 10_000])

    eventually(
      fn ->
        case ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :lookup, [manager, key]) do
          {:ok, pid} -> node(pid) == n2
          _ -> false
        end
      end,
      timeout: 10_000
    )

    assert {:ok, second} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert second.state.count == 2
    assert ExUnitCluster.call(cluster, n2, __MODULE__, :bedrock_key_count, [bedrock_prefix]) > 0

    assert %{total: 1} = ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :stats, [manager])
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

  defp handoff_key(manager, nodes, target_node) do
    Enum.find_value(1..500, fn idx ->
      key = "bedrock-handoff-#{idx}"

      if Topology.owner_node(manager, key, nodes) == target_node do
        key
      end
    end) || raise "failed to find a key owned by #{inspect(target_node)}"
  end

  defp unique_manager(prefix) do
    :"manager_#{prefix}_#{System.unique_integer([:positive])}"
  end

  def bedrock_key_count(prefix) do
    prefix |> all_keys_for_prefix() |> length()
  end

  defp assert_app_started(:ok), do: :ok
  defp assert_app_started({:ok, _apps}), do: :ok
  defp assert_app_started(other), do: raise("Failed to start app on cluster node: #{inspect(other)}")
end
