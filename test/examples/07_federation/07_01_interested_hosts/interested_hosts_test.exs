defmodule JidoCluster.Examples.InterestedEventsTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.FederationCase
  alias Jido.Cluster.Examples.InterestedEvents
  alias Jido.Cluster.Examples.InterestedEvents.Recorder
  alias Jido.Cluster.Federation.Mirror
  alias Jido.Signal.Bus
  alias JidoCluster.Examples.Support.FederationCase.OtherCluster

  @tag cluster_nodes: 3
  test "only the declared deployment and namespace receive the original event", context do
    c = start(context, InterestedEvents)
    separate = start(context, InterestedEvents, service: OtherCluster)
    first = deploy(c, InterestedEvents.new!(id: "first"))
    second = deploy(c, InterestedEvents.new!(id: "second"))
    other_namespace = deploy(separate, InterestedEvents.new!(id: "first"))
    origin = mirror(c, first, c.control)
    destination = mirror(c, first, c.target)
    isolated = mirror(c, second, c.target)
    separate_mirror = mirror(separate, other_namespace, separate.target)
    receiver = agent(c, first, :listener)
    isolated_agent = agent(c, second, :listener)
    separate_agent = agent(separate, other_namespace, :listener)
    signal = Recorder.record_signal!(7)

    assert {:ok, %{targets: [target], local: :accepted, outbound: :submitted}} =
             api(c, :publish, [first.id, :events, signal])

    assert target == c.target
    settled(c, origin)
    eventually(fn -> length(events(c, receiver)) == 1 end)
    assert events(c, receiver) == [Map.take(signal, [:id, :type, :source, :data])]
    assert {:ok, [record]} = cluster_call(c.cluster, c.target, Bus, :replay, [destination.bus, signal.type])
    assert record.signal == signal
    assert {:ok, []} = cluster_call(c.cluster, c.target, Bus, :replay, [isolated.bus, signal.type])
    assert {:ok, []} = cluster_call(c.cluster, c.target, Bus, :replay, [separate_mirror.bus, signal.type])

    assert {:error, :not_found} =
             cluster_call(c.cluster, c.unused, Mirror, :lookup, [c.jido, first.activation, "events"])

    assert {:ok, %{channels: [channel]}} = api(c, :federation_status, [first.id])
    assert channel.interested_hosts == [c.target]
    assert Enum.map(channel.hosts, & &1.host) == Enum.sort([c.control, c.target])

    # Export completion and these normal command replies close the observed batch.
    # No timed absence assertion is used for either isolated Agent.
    barrier = Recorder.record_signal!(-1)

    for pid <- [isolated_agent, separate_agent] do
      assert {:ok, _} = cluster_call(c.cluster, node(pid), Jido.AgentServer, :call, [pid, barrier])
      assert events(c, pid) == [Map.take(barrier, [:id, :type, :source, :data])]
    end

    stop_deployment(c, first)
    stop_deployment(c, second)
    stop_deployment(separate, other_namespace)

    for pid <- [receiver, isolated_agent, separate_agent],
        do: refute(cluster_call(c.cluster, node(pid), Process, :alive?, [pid]))

    cleanup(c)
    cleanup(separate)
  end
end
