defmodule JidoCluster.Examples.SharedHostTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.SharedCapacityCase
  alias Jido.Cluster.Examples.{SharedCapacity.Worker, SharedHost}

  @tag cluster_nodes: 2
  test "stopping one deployment leaves the shared host and other worker active", context do
    c = start(context, SharedHost, [{["compute"], 2}])
    {_first_ref, first} = deploy(c, SharedHost.new!(id: "first"))
    {second_ref, second} = deploy(c, SharedHost.new!(id: "second"))
    assert {:ok, _} = api(c, :call, [second_ref, Worker.work_signal!()])
    stop(c, "first")
    refute cluster_call(c.cluster, node(first), Process, :alive?, [first])
    assert [%{topology_id: "second", state: :active}] = api(c, :claims)
    assert {:ok, %{pid: ^second}} = api(c, :lookup, [second_ref])
    assert {:ok, _} = api(c, :call, [second_ref, Worker.work_signal!()])
    count(c, second, 2)

    assert %{active: 1} =
             cluster_call(c.cluster, node(second), DynamicSupervisor, :count_children, [
               Jido.agent_supervisor_name(c.jido)
             ])

    cleanup(c)
  end
end
