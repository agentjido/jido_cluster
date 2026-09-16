defmodule JidoCluster.Examples.EntityMoveTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.EntityCase

  alias Jido.Cluster.Examples.EntityMove
  alias JidoCluster.Test.MovementBarrier

  @tag cluster_nodes: 3
  test "one device keeps its Ref, state, and revision after a cooperative drain", context do
    c = start(context, [{["shared"], 1}, {["shared"], 1}])
    [source, target] = c.workers
    {:ok, workload} = EntityMove.workload()
    identity = selected_on(c, workload, source)
    assert %{state: %{count: 1, last_event: "before-move"}} = record(c, workload, identity, "before-move")
    assert {:ok, %{pid: previous, node: ^source}} = entity(c, :lookup, [workload, identity])
    assert %{state_version: 1} = snapshot(c, previous)
    assert {:ok, ref} = entity(c, :ref, [workload, identity])

    assert {:ok, _} =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {MovementBarrier, []}
             ])

    assert {:ok, drain} = api(c, :drain, [source, [request_id: api(c, :request_id)]])
    eventually(fn -> cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :status]) != [] end)
    assert {:ok, %{status: :existing, ref: ^ref}} = entity(c, :ensure, [workload, identity])
    assert Enum.sort(Enum.map(api(c, :claims), & &1.host)) == Enum.sort([source, target])
    assert :ok = cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :release])
    assert {:ok, %{phase: :completed}} = api(c, :await, [drain.id, 15_000])
    assert {:ok, ^ref} = entity(c, :ref, [workload, identity])
    assert {:ok, %{pid: current, node: ^target}} = entity(c, :lookup, [workload, identity])
    refute cluster_call(c.cluster, source, Process, :alive?, [previous])
    assert %{agent: %{state: %{count: 1, last_event: "before-move"}}, state_version: 1} = snapshot(c, current)
    assert [%{ref: ^ref, host: ^target, state: :active}] = api(c, :claims)

    assert %{state: %{count: 2, last_event: "after-move"}} = record(c, workload, identity, "after-move")
    assert %{state_version: 2} = snapshot(c, current)
    cleanup(c)
  end
end
