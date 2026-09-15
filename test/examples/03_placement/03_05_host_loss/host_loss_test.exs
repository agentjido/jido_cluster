defmodule JidoCluster.Examples.HostLossTest do
  use JidoCluster.Examples.Support.PlacementCase
  alias Jido.Cluster.Examples.UncertainHostLoss

  @tag cluster_nodes: 3
  test "loss of the source is uncertain and does not activate a second writer on spare capacity", c do
    [first, second, spare] = c.cluster.nodes
    scheduler = start_scheduler(c, UncertainHostLoss, [host(first, ["general"]), host(second)])
    ready(c, scheduler)
    old = scheduler_call(c, scheduler, :whereis_agent, [:worker])
    id = cluster_call(c.cluster, second, Jido.AgentServer, :agent, [old]).id
    assert {:ok, _} = cluster_call(c.cluster, second, Jido.AgentServer, :call, [old, Worker.work_signal!()])
    assert :ok = stop_node(c.cluster, second)
    eventually(fn -> scheduler_call(c, scheduler, :status).status == :uncertain end, timeout: 5_000)
    assert scheduler_call(c, scheduler, :status).error == {:source_unreachable, [second]}
    assert :ok = scheduler_call(c, scheduler, :update_hosts, [[host(first, ["general"]), host(spare)]])
    eventually(fn -> scheduler_call(c, scheduler, :status).status == :uncertain end)
    assert scheduler_call(c, scheduler, :status).placements == %{"worker" => second}
    assert cluster_call(c.cluster, spare, Jido, :whereis_agent, [c.jido, id]) == nil
    stop_scheduler(c, scheduler)
  end
end
