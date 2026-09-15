defmodule JidoCluster.Examples.DrainTest do
  use JidoCluster.Examples.Support.PlacementCase
  alias Jido.Agent.Ref
  alias Jido.Cluster.Examples.NodeDrain

  test "drain moves committed work while keeping the source host connected", c do
    [first, second] = c.cluster.nodes

    # Either compute host may win initial selection. Read the live PID to find
    # the source instead of hard-coding the Scheduler's placement decision.
    scheduler = start_scheduler(c, NodeDrain, [host(first), host(second)])
    ready(c, scheduler)
    old = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    source = node(old)
    target = hd(c.cluster.nodes -- [source])
    id = cluster_call(c.cluster, source, Jido.AgentServer, :agent, [old]).id

    # The Ref is logical identity and must survive movement. The old PID is
    # activation identity and must stop before the target replaces it.
    ref = Ref.new!(namespace: c.namespace, id: id)

    assert {:ok, %{state: %{count: 1}}} =
             cluster_call(c.cluster, source, Jido.AgentServer, :call, [old, Worker.work_signal!()])

    # Commit once before drain. The request accepts a cooperative move; readiness
    # separately confirms target activation and completed source evacuation.
    assert :ok = scheduler_call(c, scheduler, :drain, [source])
    status = ready(c, scheduler)
    assert status.drained == [source]
    assert status.reservations == %{target => 1}
    fresh = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    assert node(fresh) == target
    assert {:ok, ^fresh} = cluster_call(c.cluster, target, Jido, :resolve_agent, [c.jido, ref])

    # A move restores the checkpoint without adding a domain commit or replaying
    # work. Resolve the original Ref on the target and inspect its saved revision.
    assert %{agent: %{state: %{count: 1}}, state_version: 1} =
             cluster_call(c.cluster, target, Jido.AgentServer, :snapshot, [fresh])

    refute cluster_call(c.cluster, source, Process, :alive?, [old])

    # Drain stops the worker, not its Erlang host. Draining the last remaining
    # eligible host must be rejected before it disturbs the current worker.
    assert source in (cluster_call(c.cluster, target, Node, :list, []) ++ [target])
    assert {:error, {:no_capacity, "worker"}} = scheduler_call(c, scheduler, :drain, [target])
    assert ^fresh = scheduler_call(c, scheduler, :whereis_agent, [:worker])

    # Cleanup must reach the final activation on its new host.
    stop_scheduler(c, scheduler)
    refute cluster_call(c.cluster, target, Process, :alive?, [fresh])
  end
end
