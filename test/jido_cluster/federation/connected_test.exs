defmodule JidoCluster.Federation.ConnectedTest do
  use ExUnit.Case, async: true
  import JidoCluster.Test.Eventually
  alias Jido.Cluster.Federation.{Envelope, Limits}
  alias Jido.Cluster.Federation.Transport.{Connected, Receiver}
  alias Jido.Signal.Bus
  alias JidoCluster.Test.Federation.BusStore
  alias JidoCluster.Test.Federation.BusStore.Control

  setup context do
    control = start_supervised!(Control)

    bus =
      start_supervised!(
        {Bus, name: "transport-#{System.unique_integer([:positive])}", store: BusStore, store_opts: [control: control]}
      )

    {:ok, limits} = Limits.new(Keyword.merge([inbound_slots: 1], Map.get(context, :limits, [])))
    scope = {"namespace", "topology", "events"}

    receiver =
      start_supervised!(
        {Receiver, bus: bus, scope: scope, types: ["counter.changed"], limits: limits, allowed_nodes: [node()]}
      )

    sender = start_supervised!({Connected, receiver: Receiver.endpoint(receiver), ack_timeout: 100})
    endpoint = Connected.endpoint(sender)
    signal = Jido.Signal.new!(%{id: "original", type: "counter.changed", source: "/source", data: %{count: 7}})
    {:ok, envelope} = Envelope.new(scope, "source-generation", signal, limits)
    %{bus: bus, control: control, receiver: receiver, sender: sender, endpoint: endpoint, envelope: envelope}
  end

  test "credit carries the original Signal and suppresses a repeated export", c do
    assert {:ok, _} = Bus.subscribe(c.bus, "counter.changed")
    assert {:ok, :appended} = Connected.transmit(c.endpoint, c.envelope)
    assert_receive {:signal, signal}
    assert signal == c.envelope.signal
    assert {:ok, :duplicate} = Connected.transmit(c.endpoint, c.envelope)
    assert {:ok, [record]} = Bus.replay(c.bus, "counter.changed")
    assert record.signal == signal
    assert %{appended: 1, duplicates: 1, credits: 1} = Receiver.status(c.receiver)

    assert {:error, :invalid_envelope_scope} =
             Connected.transmit(c.endpoint, %{c.envelope | scope: {"other", "topology", "events"}})

    assert %{appended: 1} = Receiver.status(c.receiver)
  end

  test "a blocked receiver admits one payload while concurrent senders reject before submission", c do
    :ok = Control.hold(c.control, self())
    first = Task.async(fn -> Connected.transmit(c.endpoint, c.envelope) end)
    assert_receive {:append_waiting, control}
    assert control == c.control
    tasks = for _ <- 1..128, do: Task.async(fn -> Connected.transmit(c.endpoint, c.envelope) end)
    assert Enum.all?(Task.await_many(tasks), &(&1 == {:error, :capacity}))
    assert %{capacity: %{used_slots: 1}, pending: true} = Connected.status(c.sender)
    :ok = Control.release(c.control)
    assert Task.await(first) in [{:ok, :appended}, {:error, :ack_timeout}]
    eventually(fn -> Connected.status(c.sender).capacity.used_slots == 0 end)
    assert {:ok, [_]} = Bus.replay(c.bus, "counter.changed")
  end

  test "timeout keeps its credit charged until the delayed acknowledgement arrives", c do
    :ok = Control.hold(c.control, self())
    first = Task.async(fn -> Connected.transmit(c.endpoint, c.envelope) end)
    assert_receive {:append_waiting, _}
    assert {:error, :ack_timeout} = Task.await(first)
    assert %{health: :uncertain, pending: true, capacity: %{used_slots: 1}} = Connected.status(c.sender)
    assert {:error, :capacity} = Connected.transmit(c.endpoint, c.envelope)
    :ok = Control.release(c.control)
    eventually(fn -> Connected.status(c.sender).health == :healthy end)
    assert {:ok, :duplicate} = Connected.transmit(c.endpoint, c.envelope)
    assert {:ok, [_]} = Bus.replay(c.bus, "counter.changed")
  end

  test "append rejection does not consume duplicate identity", c do
    :ok = Control.reject(c.control)
    assert {:error, {:local_append, _}} = Connected.transmit(c.endpoint, c.envelope)
    assert {:ok, []} = Bus.replay(c.bus, "counter.changed")
    assert {:ok, :appended} = Connected.transmit(c.endpoint, c.envelope)
    assert %{appended: 1, rejected: 1} = Receiver.status(c.receiver)
  end

  test "credits bound connections and confirmed sender exit releases its exact credit", c do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    assert {:error, :capacity} =
             DynamicSupervisor.start_child(supervisor, {Connected, receiver: Receiver.endpoint(c.receiver)})

    assert :ok = stop_supervised(Connected)
    eventually(fn -> Receiver.status(c.receiver).credits == 0 end)
    assert {:error, :closed} = Connected.transmit(c.endpoint, c.envelope)
  end

  test "receiver exit closes the old sender generation", c do
    monitor = Process.monitor(c.sender)
    assert :ok = stop_supervised(Receiver)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 1000
    assert {:error, :closed} = Connected.transmit(c.endpoint, c.envelope)
  end

  @tag limits: [dedup_entries: 1]
  test "a saturated receiver cache protects the original export and rejects a new one", c do
    assert {:ok, :appended} = Connected.transmit(c.endpoint, c.envelope)
    {:ok, next} = Envelope.new(c.envelope.scope, c.envelope.generation, c.envelope.signal, c.endpoint.limits)
    assert {:error, :dedup_capacity} = Connected.transmit(c.endpoint, next)
    assert {:ok, :duplicate} = Connected.transmit(c.endpoint, c.envelope)
    assert %{appended: 1, rejected: 1, duplicates: 1} = Receiver.status(c.receiver)
    assert {:ok, [_]} = Bus.replay(c.bus, "counter.changed")
  end

  test "invalid receiver configuration fails before it grants credits", c do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    base = [
      bus: c.bus,
      scope: c.envelope.scope,
      types: ["counter.changed"],
      limits: c.endpoint.limits,
      allowed_nodes: [node()]
    ]

    for override <- [
          [allowed_nodes: []],
          [scope: {"", "id", "channel"}],
          [types: ["counter.*"]],
          [limits: %{c.endpoint.limits | inbound_slots: 0}],
          [unknown: true]
        ] do
      assert {:error, :invalid_receiver} =
               DynamicSupervisor.start_child(supervisor, {Receiver, Keyword.merge(base, override)})
    end

    assert %{active: 0} = DynamicSupervisor.count_children(supervisor)
  end
end
