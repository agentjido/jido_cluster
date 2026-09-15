defmodule JidoCluster.Examples.RecoveryTest do
  use JidoCluster.Examples.Support.PlacementCase
  alias Jido.Agent.Ref
  alias Jido.Cluster.Examples.WorkerRecovery

  test "worker exit triggers bounded core repair with the same Ref and checkpoint", c do
    [first, second] = c.cluster.nodes

    # Keep the control host and compute host alive throughout this scenario.
    # Worker exit is different from losing access to a host that may still write.
    scheduler = start_scheduler(c, WorkerRecovery, [host(first, ["general"]), host(second)])
    ready(c, scheduler)
    old = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    id = cluster_call(c.cluster, second, Jido.AgentServer, :agent, [old]).id
    ref = Ref.new!(namespace: c.namespace, id: id)
    assert {:ok, _} = cluster_call(c.cluster, second, Jido.AgentServer, :call, [old, Worker.work_signal!()])

    # Commit first, then stop only the Agent. The test never submits reconcile;
    # the Scheduler must detect the exit and request one bounded core repair.
    assert :ok = cluster_call(c.cluster, second, Jido.AgentServer, :stop, [old])

    # Require both a different PID and readiness. Cached readiness from the old
    # activation alone would not prove that replacement completed.
    eventually(
      fn ->
        fresh = scheduler_call(c, scheduler, :whereis_agent, [:worker])
        is_pid(fresh) and fresh != old and scheduler_call(c, scheduler, :status).status == :ready
      end,
      timeout: 8_000
    )

    # Repair changes the activation, while the Ref and checkpoint stay the same.
    # Count and revision must remain 1 because no new work was submitted.
    fresh = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    assert {:ok, ^fresh} = cluster_call(c.cluster, second, Jido, :resolve_agent, [c.jido, ref])

    assert %{agent: %{state: %{count: 1}}, state_version: 1} =
             cluster_call(c.cluster, second, Jido.AgentServer, :snapshot, [fresh])

    # Public repair accounting confirms that cluster policy requested recovery.
    # Stopping the Scheduler must also stop this replacement activation.
    assert scheduler_call(c, scheduler, :status).repairs >= 1
    stop_scheduler(c, scheduler)
    refute cluster_call(c.cluster, second, Process, :alive?, [fresh])
  end
end
