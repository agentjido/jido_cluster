defmodule JidoCluster.Examples.EnvelopeAndLoopsTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.FederationCase
  alias Jido.Cluster.Examples.EnvelopeAndLoops
  alias Jido.Cluster.Examples.EnvelopeAndLoops.Recorder
  alias Jido.Cluster.Federation.{Bridge, Envelope, Mirror}
  alias Jido.Cluster.Federation.Transport.{Connected, Receiver}
  alias Jido.Signal.Bus

  @tag cluster_nodes: 3
  test "imports do not loop and the same export is suppressed within the cache window", context do
    c = start(context, EnvelopeAndLoops)
    deployed = deploy(c, EnvelopeAndLoops.new!(id: "bidirectional"))
    first = mirror(c, deployed, c.control)
    second = mirror(c, deployed, c.target)
    first_agent = agent(c, deployed, :first)
    second_agent = agent(c, deployed, :second)
    signal = Recorder.record_signal!(11)
    assert {:ok, receipt} = api(c, :publish, [deployed.id, :events, signal])
    settled(c, first)
    eventually(fn -> length(events(c, first_agent)) == 1 and length(events(c, second_agent)) == 1 end)
    assert %{accepted: 0, in_flight: 0} = cluster_call(c.cluster, c.target, Bridge, :status, [second.bridge])
    assert %{appended: 0} = cluster_call(c.cluster, c.control, Receiver, :status, [first.receiver])

    # Reuse the public receipt and generation to submit the same transport identity.
    # This is protocol verification, not an application retry policy.
    {:ok, publisher} = cluster_call(c.cluster, c.control, Mirror, :publisher, [first.mirror])
    {:ok, envelope} = Envelope.new(publisher.scope, publisher.generation, signal, publisher.limits)
    repeated = %{envelope | export_id: receipt.export_id}
    sender = first[{:connection, c.target}]
    endpoint = cluster_call(c.cluster, c.control, Connected, :endpoint, [sender])
    assert {:ok, :duplicate} = cluster_call(c.cluster, c.control, Connected, :transmit, [endpoint, repeated])
    assert %{appended: 1, duplicates: 1} = cluster_call(c.cluster, c.target, Receiver, :status, [second.receiver])
    assert {:ok, [record]} = cluster_call(c.cluster, c.target, Bus, :replay, [second.bus, signal.type])
    assert record.signal == signal

    reverse = Recorder.record_signal!(22)
    {:ok, reverse_publisher} = cluster_call(c.cluster, c.target, Mirror, :publisher, [second.mirror])

    assert {:ok, %{targets: [target]}} =
             cluster_call(c.cluster, c.target, Bridge, :publish, [reverse_publisher, reverse])

    assert target == c.control
    settled(c, second)
    expected = Enum.map([signal, reverse], &Map.take(&1, [:id, :type, :source, :data]))
    eventually(fn -> events(c, first_agent) == expected and events(c, second_agent) == expected end)

    for mirror <- [first, second] do
      assert %{accepted: 1, appended: 1, in_flight: 0} =
               cluster_call(c.cluster, mirror.host, Bridge, :status, [mirror.bridge])

      assert %{appended: 1} = cluster_call(c.cluster, mirror.host, Receiver, :status, [mirror.receiver])
      assert {:ok, records} = cluster_call(c.cluster, mirror.host, Bus, :replay, [mirror.bus, signal.type])
      assert Enum.map(records, & &1.signal) == [signal, reverse]
    end

    stop_deployment(c, deployed)
    for pid <- [first_agent, second_agent], do: refute(cluster_call(c.cluster, node(pid), Process, :alive?, [pid]))
    cleanup(c)
  end
end
