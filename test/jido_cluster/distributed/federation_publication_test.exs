defmodule JidoCluster.Distributed.FederationPublicationTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster.Federation.{Bridge, Limits}
  alias Jido.Cluster.Federation.Transport.{Connected, Receiver}
  alias Jido.Signal.Bus

  @tag cluster_nodes: 3
  test "explicit publication reaches interested hosts without loops or cross-deployment delivery", c do
    [a, b, uninterested] = c.cluster.nodes
    {:ok, limits} = Limits.new([])
    scope = {"namespace", "deployment-one", "events"}
    first = mirror(c, a, scope, limits)
    second = mirror(c, b, scope, limits)
    third = mirror(c, uninterested, scope, limits)
    isolated = mirror(c, b, {"namespace", "deployment-two", "events"}, limits)
    sender_a = sender(c, first, second)
    sender_b = sender(c, second, first)
    target_a = %{host: b, transport: Connected, handle: cluster_call(c.cluster, a, Connected, :endpoint, [sender_a])}
    target_b = %{host: a, transport: Connected, handle: cluster_call(c.cluster, b, Connected, :endpoint, [sender_b])}
    assert :ok = cluster_call(c.cluster, a, Bridge, :set_targets, [first.bridge, [target_a]])
    assert :ok = cluster_call(c.cluster, b, Bridge, :set_targets, [second.bridge, [target_b]])

    signal =
      Jido.Signal.new!(%{
        id: "original",
        type: "counter.changed",
        source: "/publisher",
        data: %{count: 1, raw: <<255>>}
      })

    # Bus.publish completes local dispatch before this bridge observation. There
    # is no ordinary-local publication export waiting behind that observation.
    assert {:ok, [_]} = cluster_call(c.cluster, a, Bus, :publish, [first.bus, [signal]])
    assert %{accepted: 0, in_flight: 0} = cluster_call(c.cluster, a, Bridge, :status, [first.bridge])
    assert {:ok, []} = replay(c, second)

    assert {:ok, %{targets: [^b]}} = cluster_call(c.cluster, a, Bridge, :publish, [first.endpoint, signal])
    settled(c, first)
    assert {:ok, [record]} = replay(c, second)
    assert record.signal == signal
    assert %{accepted: 0, in_flight: 0} = cluster_call(c.cluster, b, Bridge, :status, [second.bridge])
    assert %{appended: 0} = cluster_call(c.cluster, a, Receiver, :status, [first.receiver])
    assert {:ok, []} = replay(c, third)
    assert {:ok, []} = replay(c, isolated)

    assert {:ok, %{targets: [^a]}} = cluster_call(c.cluster, b, Bridge, :publish, [second.endpoint, signal])
    settled(c, second)
    assert {:ok, records} = replay(c, first)
    assert length(records) == 3
    assert Enum.all?(records, &(&1.signal == signal))
    assert %{accepted: 1, appended: 1, in_flight: 0} = cluster_call(c.cluster, a, Bridge, :status, [first.bridge])
    assert %{accepted: 1, appended: 1, in_flight: 0} = cluster_call(c.cluster, b, Bridge, :status, [second.bridge])
    assert %{appended: 1} = cluster_call(c.cluster, b, Receiver, :status, [second.receiver])
    assert %{appended: 1} = cluster_call(c.cluster, a, Receiver, :status, [first.receiver])
    assert {:ok, []} = replay(c, third)
    assert {:ok, []} = replay(c, isolated)

    for {host, pid} <- [{a, sender_a}, {b, sender_b}], do: stop(c, host, pid)

    for mirror <- [first, second, third, isolated],
        pid <- [mirror.bridge, mirror.receiver, mirror.bus],
        do: stop(c, mirror.host, pid)
  end

  defp mirror(c, host, scope, limits) do
    bus = start(c, host, {Bus, name: "mirror-#{System.unique_integer([:positive])}", max_log_size: 64})

    receiver =
      start(
        c,
        host,
        {Receiver, bus: bus, scope: scope, types: ["counter.changed"], limits: limits, allowed_nodes: c.cluster.nodes}
      )

    bridge = start(c, host, {Bridge, bus: bus, scope: scope, types: ["counter.changed"], limits: limits, targets: []})
    endpoint = cluster_call(c.cluster, host, Bridge, :endpoint, [bridge])
    %{host: host, bus: bus, receiver: receiver, bridge: bridge, endpoint: endpoint}
  end

  defp sender(c, source, destination) do
    receiver = cluster_call(c.cluster, destination.host, Receiver, :endpoint, [destination.receiver])
    start(c, source.host, {Connected, receiver: receiver})
  end

  defp settled(c, mirror),
    do: eventually(fn -> cluster_call(c.cluster, mirror.host, Bridge, :status, [mirror.bridge]).in_flight == 0 end)

  defp replay(c, mirror), do: cluster_call(c.cluster, mirror.host, Bus, :replay, [mirror.bus, "counter.changed"])

  defp start(c, host, child) do
    assert {:ok, pid} =
             cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, child])

    pid
  end

  defp stop(c, host, pid) do
    assert :ok =
             cluster_call(c.cluster, host, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, pid])

    refute cluster_call(c.cluster, host, Process, :alive?, [pid])
  end
end
