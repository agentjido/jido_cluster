defmodule JidoCluster.Examples.EligibleNodeTest do
  use JidoCluster.Test.TopologyCase
  alias Jido.Cluster.Examples.EligibleNode

  test "policy selects the worker node and core activates the complete topology", c do
    [first, second] = c.cluster.nodes
    hosts = inventory(second) ++ [%{node: first, labels: [], available: false}]
    assert {:ok, ^second} = Placement.select({c.id, "worker"}, hosts)
    {controller, _instance} = start_topology(c, EligibleNode, %{"control" => first, "worker" => second})
    control = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :control])
    worker = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])
    assert node(control) == first
    assert node(worker) == second

    assert {:ok, %{state: %{count: 1}}} =
             cluster_call(c.cluster, second, Jido.AgentServer, :call, [worker, Counter.increment_signal!()])

    assert {:error, :no_eligible_node} = Placement.select(c.id, [%{node: first, labels: [], available: false}])
    assert :ok = stop_topology(c, controller)
    refute cluster_call(c.cluster, first, Process, :alive?, [control])
    refute cluster_call(c.cluster, second, Process, :alive?, [worker])
  end
end
