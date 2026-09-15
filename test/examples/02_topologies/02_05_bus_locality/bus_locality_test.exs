defmodule JidoCluster.Examples.BusLocalityTest do
  use JidoCluster.Test.TopologyCase
  alias Jido.Cluster.Examples.BusLocality

  test "rejected remote placement keeps the local worker and Bus working", c do
    [first, second] = c.cluster.nodes
    {controller, instance} = start_topology(c, BusLocality, %{"worker" => first})
    worker = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])
    bus = cluster_call(c.cluster, first, Controller, :whereis_bus, [controller, :events])
    spec = hd(Map.values(instance.plan.agents))
    assert {:error, :local_bus_requires_controller_node} = Placement.locality(spec, second, first)
    assert {:error, error} = cluster_call(c.cluster, first, Controller, :place_agent, [controller, :worker, second])
    assert Exception.message(error) =~ "cannot subscribe to a local Bus"
    assert ^worker = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])
    assert {:ok, _} = cluster_call(c.cluster, first, Jido.Signal.Bus, :publish, [bus, [Counter.increment_signal!()]])

    eventually(fn ->
      match?(%{agent: %{state: %{count: 1}}}, cluster_call(c.cluster, first, Jido.AgentServer, :snapshot, [worker]))
    end)

    assert :ok = stop_topology(c, controller)
    refute cluster_call(c.cluster, first, Process, :alive?, [worker])
    assert {:error, :not_found} = cluster_call(c.cluster, first, Jido.Signal.Bus, :whereis, [bus])
  end
end
