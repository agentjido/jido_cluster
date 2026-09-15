defmodule JidoCluster.Examples.StatefulMoveTest do
  use JidoCluster.Examples.Support.TopologyCase
  alias Jido.Agent.Ref
  alias Jido.Cluster.Examples.StatefulMove

  test "an exact-node move retains the core Ref, checkpoint, and commit revision", c do
    [first, second] = c.cluster.nodes

    # Start on a known source. A Ref stores namespace and Agent ID, while a PID
    # identifies only this activation and will change when the Agent moves.
    {controller, _instance} = start_topology(c, StatefulMove, %{"worker" => first})
    old = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])
    id = cluster_call(c.cluster, first, Jido.AgentServer, :agent, [old]).id
    ref = Ref.new!(namespace: c.namespace, id: id)
    assert {:ok, ^old} = cluster_call(c.cluster, first, Jido, :resolve_agent, [c.jido, ref])

    # Two normal commands create the checkpoint that the target must restore.
    for _ <- 1..2,
        do:
          assert({:ok, _} = cluster_call(c.cluster, first, Jido.AgentServer, :call, [old, Counter.increment_signal!()]))

    # The test selects the destination and requests a core move. place_agent
    # accepts the move; await_topology separately waits for target activation.
    assert {:ok, ^second} = Placement.select({c.id, "worker"}, inventory(second))
    assert :ok = cluster_call(c.cluster, first, Controller, :place_agent, [controller, :worker, second])
    await_topology(c, controller)
    fresh = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])

    # Source retirement, target location, and Ref resolution are separate
    # checks: a restored count alone would not prove that the old writer stopped.
    assert node(fresh) == second
    refute cluster_call(c.cluster, first, Process, :alive?, [old])
    assert {:ok, ^fresh} = cluster_call(c.cluster, second, Jido, :resolve_agent, [c.jido, ref])

    assert %{agent: %{id: ^id, state: %{count: 2}}, state_version: 2} =
             cluster_call(c.cluster, second, Jido.AgentServer, :snapshot, [fresh])

    # Restoring count 2 at revision 2 must not replay either earlier command.
    # A new command then proves that work continues with the next revision.
    assert {:ok, %{state: %{count: 3}}} =
             cluster_call(c.cluster, second, Jido.AgentServer, :call, [fresh, Counter.increment_signal!()])

    assert %{state_version: 3} = cluster_call(c.cluster, second, Jido.AgentServer, :snapshot, [fresh])

    # The Controller owns the moved worker too; cleanup must reach the target.
    assert :ok = stop_topology(c, controller)
    refute cluster_call(c.cluster, second, Process, :alive?, [fresh])
  end
end
