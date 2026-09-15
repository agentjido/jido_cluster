defmodule JidoCluster.Examples.KeyedCounterTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.KeyedCounter
  alias Jido.Cluster.InstanceManager
  alias Jido.Cluster.Storage.Mnesia

  setup %{cluster: cluster} do
    [n1, n2] = cluster.nodes

    # Both managers use the same replicated RAM table. A surviving node can read
    # the checkpoint after the node that ran the counter exits.
    table = shared_table(cluster, n1, n2)
    manager = :"example_counter_#{System.unique_integer([:positive])}"

    start_managers(cluster, cluster.nodes,
      name: manager,
      agent: KeyedCounter,
      namespace: "examples/cluster/keyed-counter",
      persistence: {Mnesia, table: table}
    )

    # Wait for both managers to agree on membership before testing key routing.
    # Choose a key owned by n2 so the first command from n1 must cross nodes.
    for worker <- cluster.nodes, do: await_members(cluster, worker, manager, cluster.nodes)
    {:ok, manager: manager, key: key_on(manager, cluster.nodes, n2)}
  end

  test "commands from two nodes update one committed counter", %{cluster: cluster, manager: manager, key: key} do
    [n1, n2] = cluster.nodes

    # Call the same key from different entry nodes. Routing must reach one
    # counter, so the second command adds to the first committed result.
    assert {:ok, %{state: %{count: 1}}} =
             cluster_call(cluster, n1, InstanceManager, :call, [manager, key, KeyedCounter.increment_signal!()])

    assert {:ok, %{state: %{count: 3}}} =
             cluster_call(cluster, n2, InstanceManager, :call, [manager, key, KeyedCounter.increment_signal!(2)])

    # Equal counts alone could hide two copies. Both lookups must return the
    # same live PID on the selected owner; two commands produce two commits.
    assert {:ok, first} = cluster_call(cluster, n1, InstanceManager, :lookup, [manager, key])
    assert {:ok, ^first} = cluster_call(cluster, n2, InstanceManager, :lookup, [manager, key])
    assert node(first) == n2

    assert %{agent: %{state: %{count: 3}}, state_version: 2} =
             cluster_call(cluster, n2, Jido.AgentServer, :snapshot, [first])

    # Invalid input must fail without changing either state or commit revision.
    assert {:error, _} =
             cluster_call(cluster, n1, InstanceManager, :call, [manager, key, KeyedCounter.increment_signal!(0)])

    assert %{agent: %{state: %{count: 3}}, state_version: 2} =
             cluster_call(cluster, n2, Jido.AgentServer, :snapshot, [first])
  end

  test "owner loss restores the checkpoint and commit revision", %{cluster: cluster, manager: manager, key: key} do
    [n1, n2] = cluster.nodes

    # Save two commits on n2 before removing that host from this test cluster.
    for amount <- [1, 2] do
      assert {:ok, _} =
               cluster_call(cluster, n1, InstanceManager, :call, [manager, key, KeyedCounter.increment_signal!(amount)])
    end

    # This test confirms peer exit. It does not prove safe replacement across
    # a partition. The next get request triggers restore on the surviving node.
    assert :ok = stop_node(cluster, n2)
    await_members(cluster, n1, manager, [n1])
    assert {:ok, restored} = cluster_call(cluster, n1, InstanceManager, :get, [manager, key])
    assert node(restored) == n1

    assert %{agent: %{state: %{count: 3}}, state_version: 2} =
             cluster_call(cluster, n1, Jido.AgentServer, :snapshot, [restored])

    # Restore itself must not replay work or add a commit. Only this new command
    # advances the restored count from 3 to 4 and the revision from 2 to 3.
    assert {:ok, %{state: %{count: 4}}} =
             cluster_call(cluster, n1, InstanceManager, :call, [manager, key, KeyedCounter.increment_signal!()])

    assert %{state_version: 3} = cluster_call(cluster, n1, Jido.AgentServer, :snapshot, [restored])

    # ClusterCase checks peer exit on cleanup. Check both peers here as well,
    # since this scenario deliberately stops the whole cluster.
    assert :ok = stop_node(cluster, n1)
    refute Enum.any?(cluster.peers, fn {_worker, peer} -> Process.alive?(peer) end)
  end
end
