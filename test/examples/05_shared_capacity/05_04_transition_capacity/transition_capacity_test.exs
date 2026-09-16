defmodule JidoCluster.Examples.TransitionCapacityTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.SharedCapacityCase
  alias Jido.Cluster.Examples.{SharedCapacity.Worker, TransitionCapacity}
  alias JidoCluster.Test.MovementBarrier

  @tag cluster_nodes: 3
  test "drain moves nothing without capacity and an explicit retry uses released slots", context do
    c = start(context, TransitionCapacity, [{["movable"], 1}, {["movable", "target"], 1}])
    [source, target] = c.workers
    deploy(c, TransitionCapacity.Occupant.new!(id: "occupant"))
    {ref, previous} = deploy(c, TransitionCapacity.new!(id: "moving"))
    assert node(previous) == source
    assert {:ok, _} = api(c, :call, [ref, Worker.work_signal!()])
    assert {:error, {:no_capacity, "worker"}} = api(c, :drain, [source, [request_id: api(c, :request_id)]])
    assert {:ok, %{pid: ^previous}} = api(c, :lookup, [ref])
    count(c, previous, 1)
    assert length(api(c, :claims)) == 2

    stop(c, "occupant")

    assert {:ok, _} =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {MovementBarrier, []}
             ])

    {:ok, drain} = api(c, :drain, [source, [request_id: api(c, :request_id)]])
    eventually(fn -> cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :status]) != [] end)
    assert Enum.frequencies_by(api(c, :claims), & &1.host) == %{source => 1, target => 1}
    assert :ok = cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :release])
    assert {:ok, %{phase: :completed}} = api(c, :await, [drain.id])
    assert {:ok, %{pid: current, node: ^target}} = api(c, :lookup, [ref])
    count(c, current, 1)
    refute cluster_call(c.cluster, source, Process, :alive?, [previous])
    assert [%{host: ^target, state: :active}] = api(c, :claims)
    cleanup(c)
  end
end
