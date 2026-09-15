alias Jido.Cluster.Examples.Topologies.{Counter, LocalNodes}
alias Jido.Cluster.Placement
alias Jido.Topology.Controller
alias Jido.Agent.Ref
alias Jido.Cluster.Examples.HostRecovery

LocalNodes.run(3, fn c ->
  [first, lost, replacement] = c.nodes
  {controller, _} = LocalNodes.start(c, HostRecovery, %{"worker" => lost})
  old = LocalNodes.call(c, first, Controller, :whereis_agent, [controller, :worker])
  agent = LocalNodes.call(c, lost, Jido.AgentServer, :agent, [old])
  ref = Ref.new!(namespace: c.namespace, id: agent.id)
  {:ok, _} = LocalNodes.call(c, lost, Jido.AgentServer, :call, [old, Counter.increment_signal!()])
  :ok = LocalNodes.stop_host(c, lost)

  hosts = [
    %{node: lost, labels: ["compute"], available: false},
    %{node: replacement, labels: ["compute"], available: true}
  ]

  {:ok, ^replacement} = Placement.select({c.id, "worker"}, hosts, ["compute"])
  :ok = LocalNodes.call(c, first, DynamicSupervisor, :terminate_child, [Jido.Cluster.ManagerSupervisor, controller])
  {new_controller, _} = LocalNodes.start(c, HostRecovery, %{"worker" => replacement})
  fresh = LocalNodes.call(c, first, Controller, :whereis_agent, [new_controller, :worker])
  {:ok, ^fresh} = LocalNodes.call(c, replacement, Jido, :resolve_agent, [c.jido, ref])

  %{agent: %{state: %{count: 1}}, state_version: 1} =
    LocalNodes.call(c, replacement, Jido.AgentServer, :snapshot, [fresh])

  {:ok, %{state: %{count: 2}}} =
    LocalNodes.call(c, replacement, Jido.AgentServer, :call, [fresh, Counter.increment_signal!()])

  %{same_ref: true, host_exit_confirmed: true, restored_count: 1, final_count: 2}
end)
