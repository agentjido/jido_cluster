defmodule JidoCluster.Examples.RequirementsTest do
  use JidoCluster.Examples.Support.PlacementCase
  alias Jido.Cluster.Examples.RequirementScheduling

  test "the runtime consumes requirements and selects compatible live capacity", c do
    [first, second] = c.cluster.nodes
    source = RequirementScheduling.topology()
    scheduler = start_scheduler(c, RequirementScheduling, [host(first, ["general"]), host(second)])
    status = ready(c, scheduler)
    assert status.placements == %{"worker" => second}
    assert status.reservations == %{second => 1}
    worker = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    assert node(worker) == second
    assert RequirementScheduling.topology() == source

    assert {:ok, %{state: %{count: 1}}} =
             cluster_call(c.cluster, second, Jido.AgentServer, :call, [worker, Worker.work_signal!()])

    stop_scheduler(c, scheduler)
    refute cluster_call(c.cluster, second, Process, :alive?, [worker])
  end

  test "namespace mismatch rejects a host and releases planned slots before activation", c do
    [first, second] = c.cluster.nodes
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

    scheduler = start_scheduler(c, RequirementScheduling, [host(first, ["general"]), host(second)])
    eventually(fn -> scheduler_call(c, scheduler, :status).status == :blocked end)
    assert %{error: {:incompatible_host, ^second}, reservations: %{}} = scheduler_call(c, scheduler, :status)
    assert scheduler_call(c, scheduler, :whereis_agent, [:worker]) == nil
    stop_scheduler(c, scheduler)
  end
end
