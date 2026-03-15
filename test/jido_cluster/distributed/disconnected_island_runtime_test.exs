defmodule JidoCluster.Distributed.DisconnectedIslandRuntimeTest do
  use ExUnitCluster.Case, async: false
  use JidoCluster.Test.RealBedrockClusterCase

  import JidoCluster.Test.Eventually

  @moduletag :real_bedrock
  @moduletag timeout: 60_000

  test "bedrock lease coordination acquires, renews, fails over on expiry, and rejects stale holders", %{
    cluster: cluster,
    tmp_dir: tmp_dir,
    bedrock_prefix: bedrock_prefix
  } do
    server = ExUnitCluster.start_node(cluster, join: false)
    island_a = ExUnitCluster.start_node(cluster, join: false)
    island_b = ExUnitCluster.start_node(cluster, join: false)

    ensure_apps(cluster, [server, island_a, island_b])

    write_descriptor!(tmp_dir, [server])
    assert :ok = boot_server_node!(cluster, server, tmp_dir)
    assert :ok = boot_client_node!(cluster, island_a, tmp_dir)
    assert :ok = boot_client_node!(cluster, island_b, tmp_dir)

    manager = unique_manager(:disconnected_island)
    key = "disconnected-island-1"
    signal = Jido.Signal.new!("inc", %{}, source: "/test")

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: {JidoCluster.Storage.Bedrock, storage_opts(bedrock_prefix)},
      rebalance: false,
      coordination_backend:
        {:bedrock_lease,
         [
           repo: TestRepo,
           prefix: "#{bedrock_prefix}leases/",
           ttl_ms: 250,
           renew_interval_ms: 75
         ]}
    ]

    start_managers(cluster, [island_a, island_b], opts)

    assert {:ok, first} =
             ExUnitCluster.call(cluster, island_a, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert first.state.count == 1
    assert ExUnitCluster.call(cluster, island_a, JidoCluster.InstanceManager, :owner_node, [manager, key]) == island_a

    assert ExUnitCluster.call(cluster, island_b, JidoCluster.InstanceManager, :call, [
             manager,
             key,
             signal,
             5_000
           ]) == {:error, :lease_unavailable}

    Process.sleep(100)

    assert {:ok, renewed} =
             ExUnitCluster.call(cluster, island_a, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert renewed.state.count == 2
    assert ExUnitCluster.call(cluster, island_b, JidoCluster.InstanceManager, :owner_node, [manager, key]) == island_a

    Process.sleep(350)

    assert {:ok, failed_over} =
             ExUnitCluster.call(cluster, island_b, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert failed_over.state.count == 3
    assert ExUnitCluster.call(cluster, island_b, JidoCluster.InstanceManager, :owner_node, [manager, key]) == island_b

    assert ExUnitCluster.call(cluster, island_a, JidoCluster.InstanceManager, :call, [
             manager,
             key,
             signal,
             5_000
           ]) == {:error, :lease_unavailable}

    eventually(fn ->
      ExUnitCluster.call(cluster, island_a, Jido.Agent.InstanceManager, :lookup, [manager, key]) == :error
    end)

    assert :ok = ExUnitCluster.call(cluster, island_b, JidoCluster.InstanceManager, :stop, [manager, key])

    assert {:ok, reacquired} =
             ExUnitCluster.call(cluster, island_a, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert reacquired.state.count == 4
    assert ExUnitCluster.call(cluster, island_a, JidoCluster.InstanceManager, :owner_node, [manager, key]) == island_a
  end

  defp ensure_apps(cluster, nodes) do
    Enum.each(nodes, fn node ->
      assert_app_started(ExUnitCluster.call(cluster, node, Application, :ensure_all_started, [:jido]))
      assert_app_started(ExUnitCluster.call(cluster, node, Application, :ensure_all_started, [:jido_cluster]))
    end)
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

  defp assert_app_started(:ok), do: :ok
  defp assert_app_started({:ok, _apps}), do: :ok
  defp assert_app_started(other), do: raise("Failed to start app on cluster node: #{inspect(other)}")
end
