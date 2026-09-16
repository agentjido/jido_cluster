defmodule JidoCluster.Examples.IndependentProgressTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.SharedCapacityCase
  alias Jido.Cluster.Examples.{IndependentProgress, SharedCapacity.Worker}
  alias JidoCluster.Test.MovementBarrier

  @tag cluster_nodes: 4
  test "uncertain movement retains claims while a separate allocation serves work", context do
    c = start(context, IndependentProgress, [{["moving"], 1}, {["moving"], 1}, {["independent"], 1}])
    [source, target, independent] = c.workers
    topology = selected_on(c, IndependentProgress, "moving", source)
    {ref, previous} = deploy(c, topology)
    assert {:ok, _} = api(c, :call, [ref, Worker.work_signal!()])

    assert {:ok, _} =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {MovementBarrier, []}
             ])

    {:ok, drain} = api(c, :drain, [source, [request_id: api(c, :request_id)]])
    eventually(fn -> cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :status]) != [] end)
    [%{task: task}] = cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :status])
    assert {:ok, current} = cluster_call(c.cluster, target, Jido, :resolve_agent, [c.jido, ref])
    count(c, current, 1)
    refute cluster_call(c.cluster, source, Process, :alive?, [previous])
    assert true = cluster_call(c.cluster, c.control, Process, :exit, [task, :kill])
    assert {:ok, %{phase: :uncertain, reason: {:task_exit, :killed}}} = api(c, :await, [drain.id])
    assert Enum.frequencies_by(api(c, :claims), & &1.host) == %{source => 1, target => 1}
    assert Enum.all?(api(c, :claims), &(&1.state == :uncertain))
    assert {:error, {:resources_uncertain, _}} = api(c, :drain, [source, [request_id: api(c, :request_id)]])
    assert {:error, :uncertain} = api(c, :lookup, [ref])

    {other_ref, other} = deploy(c, IndependentProgress.Separate.new!(id: "separate"))
    assert node(other) == independent
    assert {:ok, _} = api(c, :call, [other_ref, Worker.work_signal!()])
    count(c, other, 1)
    assert Enum.count(api(c, :claims), &(&1.state == :uncertain)) == 2
    assert Enum.count(api(c, :claims), &(&1.state == :active)) == 1
    cleanup(c)
  end
end
