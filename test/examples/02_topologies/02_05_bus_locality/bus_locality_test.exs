defmodule JidoCluster.Examples.BusLocalityTest do
  use JidoCluster.Examples.Support.TopologyCase
  alias Jido.Cluster.Examples.BusLocality

  test "rejected remote placement keeps the local worker and Bus working", c do
    [first, second] = c.cluster.nodes

    # The worker subscribes to a local Bus on the control host. Its placement
    # must preserve that subscription, even though another host is connected.
    {controller, instance} = start_topology(c, BusLocality, %{"worker" => first})
    worker = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])
    bus = cluster_call(c.cluster, first, Controller, :whereis_bus, [controller, :events])
    spec = hd(Map.values(instance.plan.agents))

    # Check both boundaries: policy can reject the move before submission, and
    # core must reject the same incompatible exact-node request independently.
    assert {:error, :local_bus_requires_controller_node} = Placement.locality(spec, second, first)
    assert {:error, error} = cluster_call(c.cluster, first, Controller, :place_agent, [controller, :worker, second])
    assert Exception.message(error) =~ "cannot subscribe to a local Bus"

    # A rejected move must leave the original activation and Bus input working.
    assert ^worker = cluster_call(c.cluster, first, Controller, :whereis_agent, [controller, :worker])
    assert {:ok, _} = cluster_call(c.cluster, first, Jido.Signal.Bus, :publish, [bus, [Counter.increment_signal!()]])

    # Bus publication acknowledges acceptance, not Agent commit. Observe the
    # worker's state to wait for delivery and execution without a fixed delay.
    eventually(fn ->
      match?(%{agent: %{state: %{count: 1}}}, cluster_call(c.cluster, first, Jido.AgentServer, :snapshot, [worker]))
    end)

    # This topology owns two resource kinds; cleanup must remove both.
    assert :ok = stop_topology(c, controller)
    refute cluster_call(c.cluster, first, Process, :alive?, [worker])
    assert {:error, :not_found} = cluster_call(c.cluster, first, Jido.Signal.Bus, :whereis, [bus])
  end
end
