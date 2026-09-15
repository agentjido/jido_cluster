defmodule JidoCluster.Examples.RestartTest do
  use JidoCluster.Examples.Support.PlacementCase
  alias Jido.Agent.Ref
  alias Jido.Cluster.Examples.PlacementRestart
  alias Jido.Topology.Controller

  test "restart after drain reports and reserves the restored placement", c do
    # Use two eligible hosts and read initial selection from the live worker.
    # Preserve this original inventory for the later Scheduler restart.
    hosts = Enum.map(c.cluster.nodes, &host/1)
    scheduler = start_scheduler(c, PlacementRestart, hosts)
    ready(c, scheduler)
    old = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    source = node(old)
    target = hd(c.cluster.nodes -- [source])
    id = cluster_call(c.cluster, source, Jido.AgentServer, :agent, [old]).id
    ref = Ref.new!(namespace: c.namespace, id: id)
    assert {:ok, _} = cluster_call(c.cluster, source, Jido.AgentServer, :call, [old, Worker.work_signal!()])

    # Move a committed worker and let core save its accepted target placement.
    # The same Ref and checkpoint must survive both the move and the restart.
    assert :ok = scheduler_call(c, scheduler, :drain, [source])
    assert ready(c, scheduler).placements == %{"worker" => target}
    drained = scheduler_call(c, scheduler, :whereis_agent, [:worker])

    # Normal stop removes live resources but leaves the shared persistence data.
    stop_scheduler(c, scheduler)
    refute cluster_call(c.cluster, target, Process, :alive?, [drained])

    # The same options would initially select the old source again. Restart must
    # instead retain core's eligible saved target, not report its initial plan.
    next = start_scheduler(c, PlacementRestart, hosts)
    status = ready(c, next)
    fresh = scheduler_call(c, next, :whereis_agent, [:worker])

    # Cross-check status, slot accounting, and the actual PID. The earlier fault
    # restored on target while reporting and reserving a slot on source.
    assert status.placements == %{"worker" => target}
    assert status.desired == status.placements
    assert status.reservations == %{target => 1}
    assert node(fresh) == target

    # Identity and commit history stay unchanged; neither restart nor move is work.
    assert {:ok, ^fresh} = cluster_call(c.cluster, target, Jido, :resolve_agent, [c.jido, ref])

    assert %{agent: %{state: %{count: 1}}, state_version: 1} =
             cluster_call(c.cluster, target, Jido.AgentServer, :snapshot, [fresh])

    # Stop the restarted owner and check its restored worker exits.
    stop_scheduler(c, next)
    refute cluster_call(c.cluster, target, Process, :alive?, [fresh])
  end

  test "a restarted core Controller is observed through its new PID", c do
    [first, second] = c.cluster.nodes

    # Kill only the owned core Controller. The Scheduler and its supervised
    # owner stay alive and must observe a replacement Controller PID.
    scheduler = start_scheduler(c, PlacementRestart, [host(first, ["general"]), host(second)])
    ready(c, scheduler)
    old = cluster_call(c.cluster, first, Controller, :whereis, [c.jido, c.id])
    assert true = cluster_call(c.cluster, first, Process, :exit, [old, :kill])

    # The owner waits for core ownership cleanup and child exit before starting
    # a replacement. A new Controller PID is the first recovery barrier.
    eventually(fn ->
      fresh = cluster_call(c.cluster, first, Controller, :whereis, [c.jido, c.id])
      is_pid(fresh) and fresh != old
    end)

    # A new Controller can exist before its workers are ready. The second barrier
    # requires a worker lookup and Scheduler readiness through public APIs.
    try do
      eventually(
        fn ->
          is_pid(scheduler_call(c, scheduler, :whereis_agent, [:worker])) and
            scheduler_call(c, scheduler, :status).status == :ready
        end,
        timeout: 8_000
      )
    rescue
      error in ExUnit.AssertionError ->
        # Report both layers on failure; diagnostics do not request repair.
        controller = cluster_call(c.cluster, first, Controller, :whereis, [c.jido, c.id])

        flunk(
          "#{error.message}; Scheduler: #{inspect(scheduler_call(c, scheduler, :status))}; Core: #{inspect(cluster_call(c.cluster, first, Controller, :status, [controller]))}"
        )
    end

    # Location and cleanup must still work through the new Controller; keeping
    # the old Controller PID would break lookup or leave the worker running.
    worker = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    assert node(worker) == second
    assert scheduler_call(c, scheduler, :status).placements == %{"worker" => second}
    stop_scheduler(c, scheduler)
    refute cluster_call(c.cluster, second, Process, :alive?, [worker])
  end
end
