defmodule JidoCluster.Examples.LabelExtensionTest do
  use JidoCluster.Examples.Support.TopologyCase
  alias Jido.Cluster.Examples.LabelExtension

  test "static extension requirements drive live selection without changing the source definition", c do
    [first, second] = c.cluster.nodes
    definition = LabelExtension.topology()
    labels = definition.metadata["jido.cluster.requirements"]["worker"]
    assert labels == ["compute"]
    hosts = inventory(first, ["general"]) ++ inventory(second, ["compute"])
    assert {:ok, ^second} = Placement.select({c.id, "worker"}, hosts, labels)
    {controller, _instance} = start_topology(c, LabelExtension, %{"worker" => second})
    worker = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])
    assert node(worker) == second

    assert {:ok, %{state: %{count: 1}}} =
             cluster_call(c.cluster, second, Jido.AgentServer, :call, [worker, Counter.increment_signal!()])

    assert LabelExtension.topology() == definition
    assert {:error, :no_eligible_node} = Placement.select(c.id, inventory(first, ["general"]), labels)
    assert :ok = stop_topology(c, controller)
    refute cluster_call(c.cluster, second, Process, :alive?, [worker])
  end
end
