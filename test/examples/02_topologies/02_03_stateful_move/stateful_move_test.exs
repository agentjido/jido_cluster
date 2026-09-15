defmodule JidoCluster.Examples.StatefulMoveTest do
  use JidoCluster.Examples.Support.TopologyCase
  alias Jido.Agent.Ref
  alias Jido.Cluster.Examples.StatefulMove

  test "an exact-node move retains the core Ref, checkpoint, and commit revision", c do
    [first, second] = c.cluster.nodes
    {controller, _instance} = start_topology(c, StatefulMove, %{"worker" => first})
    old = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])
    id = cluster_call(c.cluster, first, Jido.AgentServer, :agent, [old]).id
    ref = Ref.new!(namespace: c.namespace, id: id)
    assert {:ok, ^old} = cluster_call(c.cluster, first, Jido, :resolve_agent, [c.jido, ref])

    for _ <- 1..2,
        do:
          assert({:ok, _} = cluster_call(c.cluster, first, Jido.AgentServer, :call, [old, Counter.increment_signal!()]))

    assert {:ok, ^second} = Placement.select({c.id, "worker"}, inventory(second))
    assert :ok = cluster_call(c.cluster, first, Controller, :place_agent, [controller, :worker, second])
    await_topology(c, controller)
    fresh = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])
    assert node(fresh) == second
    refute cluster_call(c.cluster, first, Process, :alive?, [old])
    assert {:ok, ^fresh} = cluster_call(c.cluster, second, Jido, :resolve_agent, [c.jido, ref])

    assert %{agent: %{id: ^id, state: %{count: 2}}, state_version: 2} =
             cluster_call(c.cluster, second, Jido.AgentServer, :snapshot, [fresh])

    assert {:ok, %{state: %{count: 3}}} =
             cluster_call(c.cluster, second, Jido.AgentServer, :call, [fresh, Counter.increment_signal!()])

    assert %{state_version: 3} = cluster_call(c.cluster, second, Jido.AgentServer, :snapshot, [fresh])
    assert :ok = stop_topology(c, controller)
    refute cluster_call(c.cluster, second, Process, :alive?, [fresh])
  end
end
