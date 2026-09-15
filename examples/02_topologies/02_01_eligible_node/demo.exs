alias Jido.Cluster.Examples.Topologies.{Counter, LocalNodes}
alias Jido.Cluster.Placement
alias Jido.Topology.Controller
alias Jido.Cluster.Examples.EligibleNode

LocalNodes.run(2, fn c ->
  [first, second] = c.nodes
  hosts = [%{node: first, labels: [], available: false}, %{node: second, labels: [], available: true}]
  {:ok, ^second} = Placement.select({c.id, "worker"}, hosts)
  {controller, _} = LocalNodes.start(c, EligibleNode, %{"control" => first, "worker" => second})
  control = LocalNodes.call(c, first, Controller, :whereis_agent, [controller, :control])
  worker = LocalNodes.call(c, first, Controller, :whereis_agent, [controller, :worker])
  ^first = node(control)
  ^second = node(worker)

  {:ok, %{state: %{count: 1}}} =
    LocalNodes.call(c, second, Jido.AgentServer, :call, [worker, Counter.increment_signal!()])

  %{control_local: true, worker_remote: true, count: 1}
end)
