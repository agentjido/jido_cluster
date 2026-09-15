defmodule JidoCluster.Examples.CoordinatorTest do
  use JidoCluster.Examples.Support.PlacementCase
  alias Jido.Cluster.Examples.CoordinatorOwnership
  alias Jido.Cluster.Scheduler
  alias Jido.Topology.Controller

  test "competing connected control nodes admit only one coordinator", c do
    [first, second] = c.cluster.nodes

    # Both nodes can coordinate, but only second can run the compute worker.
    # The identical namespace and Topology ID identify one coordinator claim.
    hosts = [host(first, ["general"]), host(second)]
    opts = scheduler_opts(c, CoordinatorOwnership, hosts)

    # Independent peer channels let these starts compete. A single RPC channel
    # would serialize the requests and would not test concurrent admission.
    results =
      for control <- c.cluster.nodes do
        Task.async(fn ->
          cluster_call(c.cluster, control, DynamicSupervisor, :start_child, [
            Jido.Cluster.ManagerSupervisor,
            {Scheduler, opts}
          ])
        end)
      end
      |> Task.await_many(15_000)

    # Exactly one connected owner must be accepted. The rejected control node
    # must have no Controller, even if the accepted worker runs on that node.
    assert [{:ok, scheduler}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, {:scheduler_already_running, owner}}] = Enum.filter(results, &match?({:error, _}, &1))
    assert is_pid(owner)
    ready(c, scheduler)
    worker = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    assert node(worker) == second
    loser = hd(c.cluster.nodes -- [node(scheduler)])
    assert nil == cluster_call(c.cluster, loser, Controller, :whereis, [c.jido, c.id])

    # The accepted coordinator alone owns worker cleanup.
    stop_scheduler(c, scheduler)
    refute cluster_call(c.cluster, second, Process, :alive?, [worker])
  end

  test "a killed coordinator cleans up before another control node can restore work", c do
    [first, second] = c.cluster.nodes

    # Run coordination on first and domain work on second. Keep both hosts alive
    # so this test isolates Scheduler process exit from host replacement policy.
    hosts = [host(first, ["general"]), host(second)]
    scheduler = start_scheduler(c, CoordinatorOwnership, hosts)
    ready(c, scheduler)
    worker = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    assert {:ok, _} = cluster_call(c.cluster, second, Jido.AgentServer, :call, [worker, Worker.work_signal!()])

    # :kill skips the Scheduler's termination callback. Its separate supervised
    # owner must still cancel operations and clean up the manual core Controller.
    assert true = cluster_call(c.cluster, first, Process, :exit, [scheduler, :kill])

    # Scheduler exit alone is insufficient: a live Controller or worker would
    # remain without its repair owner. Wait for all three cleanup observations.
    eventually(
      fn ->
        not cluster_call(c.cluster, first, Process, :alive?, [scheduler]) and
          cluster_call(c.cluster, first, Controller, :whereis, [c.jido, c.id]) == nil and
          not cluster_call(c.cluster, second, Process, :alive?, [worker])
      end,
      timeout: 8_000
    )

    # Only after cleanup, request a new coordinator on the other control host.
    # The same persisted identity restores the commit, with a fresh worker PID.
    next = start_scheduler(c, CoordinatorOwnership, hosts, second)
    ready(c, next)
    fresh = scheduler_call(c, next, :whereis_agent, [:worker])
    assert fresh != worker

    assert %{agent: %{state: %{count: 1}}, state_version: 1} =
             cluster_call(c.cluster, second, Jido.AgentServer, :snapshot, [fresh])

    # The replacement coordinator must own and clean up its activation too.
    stop_scheduler(c, next)
    refute cluster_call(c.cluster, second, Process, :alive?, [fresh])
  end
end
