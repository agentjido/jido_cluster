alias Jido.Cluster.Examples.Topologies.{Counter, LocalNodes}
alias Jido.Cluster.Placement
alias Jido.Topology.Controller
alias Jido.Cluster.Examples.LabelExtension

LocalNodes.run(2, fn c ->
  [first, second] = c.nodes
  labels = LabelExtension.topology().metadata["jido.cluster.requirements"]["worker"]
  hosts = [%{node: first, labels: ["general"], available: true}, %{node: second, labels: ["compute"], available: true}]
  {:ok, ^second} = Placement.select({c.id, "worker"}, hosts, labels)
  {controller, _} = LocalNodes.start(c, LabelExtension, %{"worker" => second})
  worker = LocalNodes.call(c, first, Controller, :whereis_agent, [controller, :worker])
  ^second = node(worker)

  {:ok, %{state: %{count: 1}}} =
    LocalNodes.call(c, second, Jido.AgentServer, :call, [worker, Counter.increment_signal!()])

  %{required_labels: labels, worker_remote: true, count: 1}
end)
