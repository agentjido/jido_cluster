alias Jido.Cluster.Examples.Topologies.{Counter, LocalNodes}
alias Jido.Cluster.Placement
alias Jido.Topology.Controller
alias Jido.Agent.Ref
alias Jido.Cluster.Examples.StatefulMove

LocalNodes.run(2, fn c ->
  [first, second] = c.nodes
  {controller, _} = LocalNodes.start(c, StatefulMove, %{"worker" => first})
  old = LocalNodes.call(c, first, Controller, :whereis_agent, [controller, :worker])
  agent = LocalNodes.call(c, first, Jido.AgentServer, :agent, [old])
  ref = Ref.new!(namespace: c.namespace, id: agent.id)
  for _ <- 1..2, do: {:ok, _} = LocalNodes.call(c, first, Jido.AgentServer, :call, [old, Counter.increment_signal!()])
  {:ok, ^second} = Placement.select({c.id, "worker"}, [%{node: second, labels: [], available: true}])
  :ok = LocalNodes.call(c, first, Controller, :place_agent, [controller, :worker, second])
  :ok = LocalNodes.call(c, first, Controller, :await_ready, [controller, 10_000])
  fresh = LocalNodes.call(c, first, Controller, :whereis_agent, [controller, :worker])
  {:ok, ^fresh} = LocalNodes.call(c, second, Jido, :resolve_agent, [c.jido, ref])
  false = LocalNodes.call(c, first, Process, :alive?, [old])
  %{agent: %{state: %{count: 2}}, state_version: 2} = LocalNodes.call(c, second, Jido.AgentServer, :snapshot, [fresh])

  {:ok, %{state: %{count: 3}}} =
    LocalNodes.call(c, second, Jido.AgentServer, :call, [fresh, Counter.increment_signal!()])

  %{same_ref: true, old_stopped: true, restored_count: 2, final_count: 3}
end)
