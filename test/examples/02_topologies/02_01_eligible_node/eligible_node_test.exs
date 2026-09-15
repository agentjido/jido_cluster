defmodule JidoCluster.Examples.EligibleNodeTest do
  use JidoCluster.Examples.Support.TopologyCase
  alias Jido.Cluster.Examples.EligibleNode

  test "policy selects the worker node and core activates the complete topology", c do
    [first, second] = c.cluster.nodes

    # This core integration test owns the policy decision: only second is
    # eligible. The fixture passes exact nodes to core; no Scheduler runs here.
    hosts = inventory(second) ++ [%{node: first, labels: [], available: false}]
    assert {:ok, ^second} = Placement.select({c.id, "worker"}, hosts)
    {controller, _instance} = start_topology(c, EligibleNode, %{"control" => first, "worker" => second})

    # The Controller remains on first and activates Agents on both hosts.
    # start_topology has already waited for the complete topology to be ready.
    control = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :control])
    worker = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])
    assert node(control) == first
    assert node(worker) == second

    # A PID lookup proves location. A normal command also proves that the
    # remotely activated Agent can execute and commit work.
    assert {:ok, %{state: %{count: 1}}} =
             cluster_call(c.cluster, second, Jido.AgentServer, :call, [worker, Counter.increment_signal!()])

    # No eligible host is a policy error. Stopping the Controller must also
    # remove its remote worker, not just the local control Agent.
    assert {:error, :no_eligible_node} = Placement.select(c.id, [%{node: first, labels: [], available: false}])
    assert :ok = stop_topology(c, controller)
    refute cluster_call(c.cluster, first, Process, :alive?, [control])
    refute cluster_call(c.cluster, second, Process, :alive?, [worker])
  end
end
