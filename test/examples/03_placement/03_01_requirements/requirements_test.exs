defmodule JidoCluster.Examples.RequirementsTest do
  use JidoCluster.Examples.Support.PlacementCase
  alias Jido.Cluster.Examples.RequirementScheduling

  test "the runtime consumes requirements and selects compatible live capacity", c do
    [first, second] = c.cluster.nodes

    # Give the runtime requirements and inventory, with no exact worker node.
    # Only second has the compute label; the Scheduler must make that selection.
    source = RequirementScheduling.topology()
    scheduler = start_scheduler(c, RequirementScheduling, [host(first, ["general"]), host(second)])

    # Starting the Scheduler returns before placement completes. Wait for its
    # public readiness result, then compare the planned location with the PID.
    status = ready(c, scheduler)
    assert status.placements == %{"worker" => second}
    assert status.reservations == %{second => 1}
    worker = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    assert node(worker) == second

    # Runtime selection must not change the reusable static Topology definition.
    assert RequirementScheduling.topology() == source

    # A normal command proves the selected activation can execute and commit.
    assert {:ok, %{state: %{count: 1}}} =
             cluster_call(c.cluster, second, Jido.AgentServer, :call, [worker, Worker.work_signal!()])

    # Stopping the repair owner must stop its remote worker. ClusterCase checks
    # peer process cleanup separately.
    stop_scheduler(c, scheduler)
    refute cluster_call(c.cluster, second, Process, :alive?, [worker])
  end

  test "namespace mismatch rejects a host and releases planned slots before activation", c do
    [first, second] = c.cluster.nodes

    # Keep the same service name on second but change its identity namespace.
    # Labels and connectivity are insufficient to make that host compatible.
    instance = cluster_call(c.cluster, second, Process, :whereis, [c.jido])

    assert :ok =
             cluster_call(c.cluster, second, DynamicSupervisor, :terminate_child, [
               Jido.Cluster.ManagerSupervisor,
               instance
             ])

    assert {:ok, _} =
             cluster_call(c.cluster, second, DynamicSupervisor, :start_child, [
               Jido.Cluster.ManagerSupervisor,
               {Jido, name: c.jido, namespace: "incompatible/namespace"}
             ])

    # The compute host passes label selection but must fail namespace validation
    # before worker activation. Rejected admission releases its planned slots.
    scheduler = start_scheduler(c, RequirementScheduling, [host(first, ["general"]), host(second)])
    eventually(fn -> scheduler_call(c, scheduler, :status).status == :blocked end)
    assert %{error: {:incompatible_host, ^second}, reservations: %{}} = scheduler_call(c, scheduler, :status)
    assert scheduler_call(c, scheduler, :whereis_agent, [:worker]) == nil

    # A blocked Scheduler still owns its coordinator claim and needs cleanup.
    stop_scheduler(c, scheduler)
  end
end
