defmodule JidoCluster.Examples.RestartTest do
  use JidoCluster.Examples.Support.PlacementCase
  alias Jido.Agent.Ref
  alias Jido.Cluster.Examples.PlacementRestart
  alias Jido.Topology.Controller

  test "restart after drain reports and reserves the restored placement", c do
    hosts = Enum.map(c.cluster.nodes, &host/1)
    scheduler = start_scheduler(c, PlacementRestart, hosts)
    ready(c, scheduler)
    old = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    source = node(old)
    target = hd(c.cluster.nodes -- [source])
    id = cluster_call(c.cluster, source, Jido.AgentServer, :agent, [old]).id
    ref = Ref.new!(namespace: c.namespace, id: id)
    assert {:ok, _} = cluster_call(c.cluster, source, Jido.AgentServer, :call, [old, Worker.work_signal!()])
    assert :ok = scheduler_call(c, scheduler, :drain, [source])
    assert ready(c, scheduler).placements == %{"worker" => target}
    drained = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    stop_scheduler(c, scheduler)
    refute cluster_call(c.cluster, target, Process, :alive?, [drained])

    next = start_scheduler(c, PlacementRestart, hosts)
    status = ready(c, next)
    fresh = scheduler_call(c, next, :whereis_agent, [:worker])
    assert status.placements == %{"worker" => target}
    assert status.desired == status.placements
    assert status.reservations == %{target => 1}
    assert node(fresh) == target
    assert {:ok, ^fresh} = cluster_call(c.cluster, target, Jido, :resolve_agent, [c.jido, ref])

    assert %{agent: %{state: %{count: 1}}, state_version: 1} =
             cluster_call(c.cluster, target, Jido.AgentServer, :snapshot, [fresh])

    stop_scheduler(c, next)
    refute cluster_call(c.cluster, target, Process, :alive?, [fresh])
  end

  test "a restarted core Controller is observed through its new PID", c do
    [first, second] = c.cluster.nodes
    scheduler = start_scheduler(c, PlacementRestart, [host(first, ["general"]), host(second)])
    ready(c, scheduler)
    old = cluster_call(c.cluster, first, Controller, :whereis, [c.jido, c.id])
    assert true = cluster_call(c.cluster, first, Process, :exit, [old, :kill])

    eventually(fn ->
      fresh = cluster_call(c.cluster, first, Controller, :whereis, [c.jido, c.id])
      is_pid(fresh) and fresh != old
    end)

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
        controller = cluster_call(c.cluster, first, Controller, :whereis, [c.jido, c.id])

        flunk(
          "#{error.message}; Scheduler: #{inspect(scheduler_call(c, scheduler, :status))}; Core: #{inspect(cluster_call(c.cluster, first, Controller, :status, [controller]))}"
        )
    end

    worker = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    assert node(worker) == second
    assert scheduler_call(c, scheduler, :status).placements == %{"worker" => second}
    stop_scheduler(c, scheduler)
    refute cluster_call(c.cluster, second, Process, :alive?, [worker])
  end
end
