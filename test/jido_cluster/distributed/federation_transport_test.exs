defmodule JidoCluster.Distributed.FederationTransportTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster.Federation.{Envelope, Limits}
  alias Jido.Cluster.Federation.Transport.{Connected, Receiver}
  alias Jido.Signal.Bus
  alias JidoCluster.Test.Federation.BusStore
  alias JidoCluster.Test.Federation.BusStore.Control

  @tag cluster_nodes: 3
  test "real BEAM transport retains one blocked credit and rejects another host at capacity", c do
    [source, target, spare] = c.cluster.nodes
    {:ok, limits} = Limits.new(inbound_slots: 1)
    scope = {"transport", "peer-proof", "events"}
    control = start(c, target, {Control, []})
    bus = start(c, target, {Bus, name: "peer-transport", store: BusStore, store_opts: [control: control]})

    receiver =
      start(
        c,
        target,
        {Receiver, bus: bus, scope: scope, types: ["counter.changed"], limits: limits, allowed_nodes: [source, spare]}
      )

    destination = cluster_call(c.cluster, target, Receiver, :endpoint, [receiver])
    sender = start(c, source, {Connected, receiver: destination, ack_timeout: 100})
    endpoint = cluster_call(c.cluster, source, Connected, :endpoint, [sender])

    signal =
      Jido.Signal.new!(%{
        id: "peer-original",
        type: "counter.changed",
        source: "/source",
        data: %{count: 3, raw: <<255>>},
        extensions: %{"trace" => "peer-trace"}
      })

    {:ok, first} = Envelope.new(scope, "source-generation", signal, limits)
    assert {:ok, :appended} = cluster_call(c.cluster, source, Connected, :transmit, [endpoint, first])
    assert {:ok, :duplicate} = cluster_call(c.cluster, source, Connected, :transmit, [endpoint, first])
    assert {:ok, [record]} = cluster_call(c.cluster, target, Bus, :replay, [bus, "counter.changed"])
    assert record.signal == signal

    assert {:error, :capacity} =
             cluster_call(c.cluster, spare, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {Connected, receiver: destination}
             ])

    assert %{active: 0} =
             cluster_call(c.cluster, spare, DynamicSupervisor, :count_children, [JidoCluster.Test.Supervisor])

    assert :ok = cluster_call(c.cluster, target, Control, :hold, [control, nil])
    {:ok, second} = Envelope.new(scope, "source-generation", signal, limits)
    assert {:error, :ack_timeout} = cluster_call(c.cluster, source, Connected, :transmit, [endpoint, second])

    assert %{health: :uncertain, capacity: %{used_slots: 1}} =
             cluster_call(c.cluster, source, Connected, :status, [sender])

    for _ <- 1..32 do
      assert {:error, :capacity} = cluster_call(c.cluster, source, Connected, :transmit, [endpoint, second])
    end

    assert :ok = cluster_call(c.cluster, target, Control, :release, [control])
    eventually(fn -> cluster_call(c.cluster, source, Connected, :status, [sender]).health == :healthy end)
    assert %{appended: 2, duplicates: 1, credits: 1} = cluster_call(c.cluster, target, Receiver, :status, [receiver])
    assert {:ok, [_, _]} = cluster_call(c.cluster, target, Bus, :replay, [bus, "counter.changed"])

    stop(c, source, sender)
    eventually(fn -> cluster_call(c.cluster, target, Receiver, :status, [receiver]).credits == 0 end)
    for pid <- [receiver, bus, control], do: stop(c, target, pid)
  end

  test "disconnect keeps an unacknowledged credit charged even after the sender exits", c do
    [source, target] = c.cluster.nodes
    {:ok, limits} = Limits.new(inbound_slots: 1)
    scope = {"transport", "disconnect", "events"}
    control = start(c, target, {Control, []})
    bus = start(c, target, {Bus, name: "disconnected-transport", store: BusStore, store_opts: [control: control]})

    receiver =
      start(
        c,
        target,
        {Receiver, bus: bus, scope: scope, types: ["counter.changed"], limits: limits, allowed_nodes: [source]}
      )

    destination = cluster_call(c.cluster, target, Receiver, :endpoint, [receiver])
    sender = start(c, source, {Connected, receiver: destination, ack_timeout: 100})
    endpoint = cluster_call(c.cluster, source, Connected, :endpoint, [sender])
    signal = Jido.Signal.new!(%{type: "counter.changed", source: "/source", data: %{count: 1}})
    {:ok, envelope} = Envelope.new(scope, "source-generation", signal, limits)
    assert :ok = cluster_call(c.cluster, target, Control, :hold, [control, nil])
    assert {:error, :ack_timeout} = cluster_call(c.cluster, source, Connected, :transmit, [endpoint, envelope])
    cookie = cluster_call(c.cluster, source, Node, :get_cookie, [])
    on_exit(fn -> reconnect(c, source, target, cookie) end)
    assert true = cluster_call(c.cluster, source, Node, :set_cookie, [target, :transport_source_partition])
    assert true = cluster_call(c.cluster, target, Node, :set_cookie, [source, :transport_target_partition])
    cluster_call(c.cluster, source, Node, :disconnect, [target])
    cluster_call(c.cluster, target, Node, :disconnect, [source])

    eventually(fn ->
      cluster_call(c.cluster, source, Node, :list, []) == [] and cluster_call(c.cluster, target, Node, :list, []) == []
    end)

    assert :ok = cluster_call(c.cluster, target, Control, :release, [control])
    eventually(fn -> cluster_call(c.cluster, target, Receiver, :status, [receiver]).uncertain_credits == 1 end)

    assert %{health: :uncertain, capacity: %{used_slots: 1}} =
             cluster_call(c.cluster, source, Connected, :status, [sender])

    assert {:error, :capacity} = cluster_call(c.cluster, source, Connected, :transmit, [endpoint, envelope])
    stop(c, source, sender)
    reconnect(c, source, target, cookie)

    assert %{credits: 1, uncertain_credits: 1, appended: 1} =
             cluster_call(c.cluster, target, Receiver, :status, [receiver])

    assert {:error, :capacity} =
             cluster_call(c.cluster, source, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {Connected, receiver: destination}
             ])

    for pid <- [receiver, bus, control], do: stop(c, target, pid)
  end

  defp reconnect(c, source, target, cookie) do
    for {host, other} <- [{source, target}, {target, source}] do
      assert true = cluster_call(c.cluster, host, Node, :set_cookie, [other, cookie])
    end

    assert true = cluster_call(c.cluster, source, Node, :connect, [target])
    eventually(fn -> target in cluster_call(c.cluster, source, Node, :list, []) end)
  end

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
