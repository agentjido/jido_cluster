defmodule JidoCluster.Examples.CoordinatorTest do
  use JidoCluster.Examples.Support.PlacementCase
  alias Jido.Cluster.Examples.CoordinatorOwnership
  alias Jido.Cluster.Scheduler
  alias Jido.Topology.Controller

  test "competing connected control nodes admit only one coordinator", c do
    [first, second] = c.cluster.nodes
    hosts = [host(first, ["general"]), host(second)]
    opts = scheduler_opts(c, CoordinatorOwnership, hosts)

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

    assert [{:ok, scheduler}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, {:scheduler_already_running, owner}}] = Enum.filter(results, &match?({:error, _}, &1))
    assert is_pid(owner)
    ready(c, scheduler)
    worker = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    assert node(worker) == second
    loser = hd(c.cluster.nodes -- [node(scheduler)])
    assert nil == cluster_call(c.cluster, loser, Controller, :whereis, [c.jido, c.id])
    stop_scheduler(c, scheduler)
    refute cluster_call(c.cluster, second, Process, :alive?, [worker])
  end

  test "a killed coordinator cleans up before another control node can restore work", c do
    [first, second] = c.cluster.nodes
    hosts = [host(first, ["general"]), host(second)]
    scheduler = start_scheduler(c, CoordinatorOwnership, hosts)
    ready(c, scheduler)
    worker = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    assert {:ok, _} = cluster_call(c.cluster, second, Jido.AgentServer, :call, [worker, Worker.work_signal!()])
    assert true = cluster_call(c.cluster, first, Process, :exit, [scheduler, :kill])

    eventually(
      fn ->
        not cluster_call(c.cluster, first, Process, :alive?, [scheduler]) and
          cluster_call(c.cluster, first, Controller, :whereis, [c.jido, c.id]) == nil and
          not cluster_call(c.cluster, second, Process, :alive?, [worker])
      end,
      timeout: 8_000
    )

    next = start_scheduler(c, CoordinatorOwnership, hosts, second)
    ready(c, next)
    fresh = scheduler_call(c, next, :whereis_agent, [:worker])
    assert fresh != worker

    assert %{agent: %{state: %{count: 1}}, state_version: 1} =
             cluster_call(c.cluster, second, Jido.AgentServer, :snapshot, [fresh])

    stop_scheduler(c, next)
    refute cluster_call(c.cluster, second, Process, :alive?, [fresh])
  end
end
