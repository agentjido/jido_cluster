alias Jido.Cluster.Examples.Topologies.{Counter, LocalNodes}
alias Jido.Cluster.Placement
alias Jido.Topology.Controller
alias Jido.Cluster.Examples.BusLocality

LocalNodes.run(2, fn c ->
  [first, second] = c.nodes
  {controller, instance} = LocalNodes.start(c, BusLocality, %{"worker" => first})
  worker = LocalNodes.call(c, first, Controller, :whereis_agent, [controller, :worker])
  bus = LocalNodes.call(c, first, Controller, :whereis_bus, [controller, :events])
  spec = hd(Map.values(instance.plan.agents))
  {:error, :local_bus_requires_controller_node} = Placement.locality(spec, second, first)
  {:error, _} = LocalNodes.call(c, first, Controller, :place_agent, [controller, :worker, second])
  ^worker = LocalNodes.call(c, first, Controller, :whereis_agent, [controller, :worker])
  {:ok, _} = LocalNodes.call(c, first, Jido.Signal.Bus, :publish, [bus, [Counter.increment_signal!()]])

  LocalNodes.await(fn ->
    match?(%{agent: %{state: %{count: 1}}}, LocalNodes.call(c, first, Jido.AgentServer, :snapshot, [worker]))
  end)

  %{remote_move_rejected: true, same_worker: true, bus_delivery_count: 1}
end)
