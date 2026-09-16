defmodule JidoCluster.Examples.EntityMixedDemandTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.EntityCase

  alias Jido.Cluster.Examples.EntityMixedDemand
  alias Jido.Cluster.Examples.EntityMixedDemand.Occupant

  @tag cluster_nodes: 3
  test "declared demand blocks entity activation until its shared claim is released", context do
    c = start(context, [{["shared"], 1}, {["shared"], 0}])
    {:ok, workload} = EntityMixedDemand.workload()
    identity = {"devices", "waiting"}
    declared = Occupant.new!(id: "declared-worker")
    assert {:ok, operation} = api(c, :deploy, [declared, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])
    assert {:error, {:no_capacity, "entity"}} = entity(c, :ensure, [workload, identity])
    assert {:error, :not_found} = entity(c, :lookup, [workload, identity])
    assert [%{topology_id: "declared-worker", state: :active}] = api(c, :claims)

    assert {:ok, stop} = api(c, :stop, ["declared-worker", [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [stop.id])
    assert %{state: %{count: 1, last_event: "admitted"}} = record(c, workload, identity, "admitted")
    assert {:ok, %{pid: pid}} = entity(c, :lookup, [workload, identity])
    assert %{state_version: 1} = snapshot(c, pid)
    assert [%{topology_id: id, state: :active}] = api(c, :claims)
    assert {:ok, %{topology_id: ^id}} = entity(c, :ensure, [workload, identity])
    cleanup(c)
  end
end
