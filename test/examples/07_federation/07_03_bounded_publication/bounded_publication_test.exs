defmodule JidoCluster.Examples.BoundedPublicationTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.FederationCase
  alias Jido.Cluster.Examples.BoundedPublication
  alias Jido.Cluster.Examples.BoundedPublication.Recorder
  alias Jido.Cluster.Federation.Bridge
  alias Jido.Signal.Bus
  alias JidoCluster.Test.Federation.RecordingTransport

  @tag cluster_nodes: 3
  test "held submissions fill the queue and later loss does not undo local acceptance", context do
    c = start(context, BoundedPublication)
    deployed = deploy(c, BoundedPublication.new!(id: "bounded"))
    origin = mirror(c, deployed, c.control)
    receiver = agent(c, deployed, :listener)
    transport = child(c, c.control, {RecordingTransport, []})
    handle = cluster_call(c.cluster, c.control, RecordingTransport, :endpoint, [transport])
    targets = [%{host: c.target, transport: RecordingTransport, handle: handle}]
    assert :ok = cluster_call(c.cluster, c.control, Bridge, :set_targets, [origin.bridge, targets])
    assert :ok = cluster_call(c.cluster, c.control, RecordingTransport, :hold, [transport])
    first = Recorder.record_signal!(1)
    second = Recorder.record_signal!(2)

    for signal <- [first, second],
        do: assert({:ok, %{local: :accepted, outbound: :submitted}} = api(c, :publish, [deployed.id, :events, signal]))

    eventually(fn -> cluster_call(c.cluster, c.control, RecordingTransport, :pending, [transport]) == 2 end)
    assert {:ok, %{channels: [channel]}} = api(c, :federation_status, [deployed.id])
    source = Enum.find(channel.hosts, &(&1.host == c.control))
    assert %{accepted: 2, in_flight: 2, capacity: %{used_slots: 2}} = source.exports
    assert {:error, :capacity} = api(c, :publish, [deployed.id, :events, Recorder.record_signal!(3)])
    assert {:ok, records} = cluster_call(c.cluster, c.control, Bus, :replay, [origin.bus, first.type])
    assert Enum.map(records, & &1.signal) == [first, second]
    exports = cluster_call(c.cluster, c.control, RecordingTransport, :exports, [transport])
    assert Enum.sort(Enum.map(exports, & &1.signal.id)) == Enum.sort([first.id, second.id])
    assert :ok = cluster_call(c.cluster, c.control, RecordingTransport, :release, [transport, {:ok, :appended}])
    settled(c, origin)

    assert %{capacity: %{used_slots: 0}, appended: 2} =
             cluster_call(c.cluster, c.control, Bridge, :status, [origin.bridge])

    assert :ok = cluster_call(c.cluster, c.control, RecordingTransport, :mode, [transport, {:error, :noconnect}])
    lost = Recorder.record_signal!(4)
    assert {:ok, %{local: :accepted}} = api(c, :publish, [deployed.id, :events, lost])
    settled(c, origin)
    assert {:ok, %{channels: [channel]}} = api(c, :federation_status, [deployed.id])
    source = Enum.find(channel.hosts, &(&1.host == c.control))
    assert %{accepted: 3, appended: 2, rejected: 1, health: :degraded} = source.exports
    assert {:ok, records} = cluster_call(c.cluster, c.control, Bus, :replay, [origin.bus, first.type])
    assert Enum.map(records, & &1.signal) == [first, second, lost]
    assert {:ok, %{phase: :completed}} = api(c, :operation, [deployed.operation])
    stop_deployment(c, deployed)
    refute cluster_call(c.cluster, c.target, Process, :alive?, [receiver])
    stop_child(c, c.control, transport)
    cleanup(c)
  end
end
