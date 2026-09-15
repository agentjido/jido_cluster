defmodule JidoCluster.Examples.HostRecoveryTest do
  use JidoCluster.Examples.Support.TopologyCase
  alias Jido.Agent.Ref
  alias Jido.Cluster.Examples.HostRecovery

  @tag cluster_nodes: 3
  test "confirmed host exit permits explicit controller replacement on compatible capacity", c do
    [first, lost, replacement] = c.cluster.nodes

    # first is the control host. Keep a third compatible host available so the
    # test can choose replacement capacity after it confirms lost has exited.
    {controller, _instance} = start_topology(c, HostRecovery, %{"worker" => lost})
    old = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])
    id = cluster_call(c.cluster, first, Jido.AgentServer, :agent, [old]).id
    ref = Ref.new!(namespace: c.namespace, id: id)

    # Commit domain state while the original host is still reachable.
    assert {:ok, %{state: %{count: 1}}} =
             cluster_call(c.cluster, lost, Jido.AgentServer, :call, [old, Counter.increment_signal!()])

    # The test knows this peer stopped. Unreachability alone would not grant
    # production code permission to replace a writer across a partition.
    assert :ok = stop_node(c.cluster, lost)
    hosts = inventory(replacement, ["compute"]) ++ [%{node: lost, labels: ["compute"], available: false}]
    assert {:ok, ^replacement} = Placement.select({c.id, "worker"}, hosts, ["compute"])

    # Replacement is explicit application coordination in this example. Stop
    # the old Controller and wait for cleanup before starting a new exact target.
    assert :ok = stop_topology(c, controller)
    {new_controller, restored_instance} = start_topology(c, HostRecovery, %{"worker" => replacement})

    # The same Topology ID gives the worker the same logical identity. Shared
    # persistence restores its saved state even though its host and PID change.
    assert hd(Map.values(restored_instance.plan.agents)).id == id
    fresh = cluster_call(c.cluster, first, Controller, :whereis_agent, [new_controller, :worker])
    assert node(fresh) == replacement
    assert {:ok, ^fresh} = cluster_call(c.cluster, replacement, Jido, :resolve_agent, [c.jido, ref])

    assert %{agent: %{state: %{count: 1}}, state_version: 1} =
             cluster_call(c.cluster, replacement, Jido.AgentServer, :snapshot, [fresh])

    # One new command continues from the saved count; this is not Signal replay.
    assert {:ok, %{state: %{count: 2}}} =
             cluster_call(c.cluster, replacement, Jido.AgentServer, :call, [fresh, Counter.increment_signal!()])

    # Also prove ownership cleanup for the replacement Controller and worker.
    assert :ok = stop_topology(c, new_controller)
    refute cluster_call(c.cluster, replacement, Process, :alive?, [fresh])
  end
end
