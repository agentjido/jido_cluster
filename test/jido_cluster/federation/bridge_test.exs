defmodule JidoCluster.Federation.BridgeTest do
  use ExUnit.Case, async: true
  import JidoCluster.Test.Eventually
  alias Jido.Cluster.Federation.{Bridge, Gate, Limits}
  alias Jido.Signal.Bus
  alias JidoCluster.Test.Federation.{BusStore, RecordingTransport}
  alias JidoCluster.Test.Federation.BusStore.Control

  setup do
    control = start_supervised!(Control)

    bus =
      start_supervised!(
        {Bus, name: "bridge-#{System.unique_integer([:positive])}", store: BusStore, store_opts: [control: control]}
      )

    transport = start_supervised!(RecordingTransport)
    {:ok, limits} = Limits.new(outbound_slots: 2)
    scope = {"namespace", "topology", "events"}

    targets = [
      %{host: :interested@local, transport: RecordingTransport, handle: RecordingTransport.endpoint(transport)}
    ]

    bridge =
      start_supervised!({Bridge, bus: bus, scope: scope, types: ["counter.changed"], limits: limits, targets: targets})

    endpoint = Bridge.endpoint(bridge)
    signal = Jido.Signal.new!(%{id: "original", type: "counter.changed", source: "/source", data: %{count: 1}})

    %{
      bridge: bridge,
      endpoint: endpoint,
      transport: transport,
      control: control,
      bus: bus,
      signal: signal,
      targets: targets
    }
  end

  test "receipt confirms local append and bounded submission before transport finishes", c do
    :ok = RecordingTransport.hold(c.transport)
    assert {:ok, receipt} = Bridge.publish(c.endpoint, c.signal)
    assert receipt.scope == c.endpoint.scope
    assert receipt.signal_id == c.signal.id
    assert receipt.local == :accepted
    assert receipt.outbound == :submitted
    assert receipt.targets == [:interested@local]
    assert {:ok, [record]} = Bus.replay(c.bus, "counter.changed")
    assert record.signal == c.signal
    eventually(fn -> RecordingTransport.pending(c.transport) == 1 end)
    assert [envelope] = RecordingTransport.exports(c.transport)
    assert envelope.signal == c.signal
    assert envelope.export_id == receipt.export_id
    assert %{in_flight: 1, accepted: 1, appended: 0} = Bridge.status(c.bridge)
    :ok = RecordingTransport.release(c.transport, {:ok, :appended})
    eventually(fn -> Bridge.status(c.bridge).in_flight == 0 end)
    assert %{appended: 1, health: :healthy, capacity: %{used_slots: 0}} = Bridge.status(c.bridge)
  end

  test "full outbound capacity rejects before local append, including concurrent callers", c do
    :ok = RecordingTransport.hold(c.transport)
    for _ <- 1..2, do: assert({:ok, _} = Bridge.publish(c.endpoint, c.signal))
    eventually(fn -> RecordingTransport.pending(c.transport) == 2 end)
    tasks = for _ <- 1..128, do: Task.async(fn -> Bridge.publish(c.endpoint, c.signal) end)
    assert Enum.all?(Task.await_many(tasks), &(&1 == {:error, :capacity}))
    assert {:ok, [_, _]} = Bus.replay(c.bus, "counter.changed")
    assert length(RecordingTransport.exports(c.transport)) == 2
    :ok = RecordingTransport.release(c.transport, {:error, :noconnect})
    eventually(fn -> Bridge.status(c.bridge).in_flight == 0 end)
    assert %{accepted: 2, rejected: 2, health: :degraded} = Bridge.status(c.bridge)
    assert {:ok, [_, _]} = Bus.replay(c.bus, "counter.changed")
  end

  test "local append rejection releases the reservation and submits no export", c do
    :ok = Control.reject(c.control)
    assert {:error, {:local_append, _}} = Bridge.publish(c.endpoint, c.signal)
    assert RecordingTransport.exports(c.transport) == []
    assert {:ok, []} = Bus.replay(c.bus, "counter.changed")
    assert %{accepted: 0, capacity: %{used_slots: 0}} = Bridge.status(c.bridge)
    assert {:ok, _} = Bridge.publish(c.endpoint, c.signal)
    eventually(fn -> Bridge.status(c.bridge).appended == 1 end)
  end

  test "ordinary local Bus publishes do not become federation exports", c do
    assert {:ok, [_]} = Bus.publish(c.bus, [c.signal])
    assert %{accepted: 0, in_flight: 0} = Bridge.status(c.bridge)
    assert RecordingTransport.exports(c.transport) == []
  end

  test "invalid types and oversize values fail before local append", c do
    assert {:error, :type_not_allowed} = Bridge.publish(c.endpoint, %{c.signal | type: "other.changed"})
    assert {:error, :envelope_too_large} = Bridge.publish(c.endpoint, %{c.signal | data: String.duplicate("x", 16_384)})
    assert {:ok, []} = Bus.replay(c.bus, "counter.changed")
    assert RecordingTransport.exports(c.transport) == []
  end

  test "transport exception reports uncertainty without rolling back local acceptance", c do
    :ok = RecordingTransport.mode(c.transport, :raise)
    assert {:ok, _} = Bridge.publish(c.endpoint, c.signal)
    eventually(fn -> Bridge.status(c.bridge).in_flight == 0 end)
    assert %{uncertain: 1, accepted: 1, health: :degraded} = Bridge.status(c.bridge)
    assert {:ok, [_]} = Bus.replay(c.bus, "counter.changed")
  end

  test "interest updates reject duplicates and cannot retire a target with work in flight", c do
    assert {:error, :invalid_targets} = Bridge.set_targets(c.bridge, c.targets ++ c.targets)
    :ok = RecordingTransport.hold(c.transport)
    assert {:ok, _} = Bridge.publish(c.endpoint, c.signal)
    eventually(fn -> RecordingTransport.pending(c.transport) == 1 end)
    assert {:error, :busy} = Bridge.set_targets(c.bridge, [])
    :ok = RecordingTransport.release(c.transport, {:ok, :appended})
    eventually(fn -> Bridge.status(c.bridge).in_flight == 0 end)
    assert :ok = Bridge.set_targets(c.bridge, [])
    assert {:ok, %{targets: []}} = Bridge.publish(c.endpoint, c.signal)
    assert length(RecordingTransport.exports(c.transport)) == 1
    assert {:ok, [_, _]} = Bus.replay(c.bus, "counter.changed")
  end

  test "publication timeout retains admission until the delayed append and export finish", c do
    :ok = Control.hold(c.control, self())
    assert {:error, :publication_uncertain} = Bridge.publish(c.endpoint, c.signal, 10)
    assert_receive {:append_waiting, _}
    assert %{used_slots: 1} = Gate.status(c.endpoint.gate)
    assert RecordingTransport.exports(c.transport) == []
    :ok = Control.release(c.control)
    eventually(fn -> Bridge.status(c.bridge).appended == 1 end)
    assert %{capacity: %{used_slots: 0}, accepted: 1} = Bridge.status(c.bridge)
    assert {:ok, [_]} = Bus.replay(c.bus, "counter.changed")
  end

  test "one destination failure does not prevent another destination's submission", c do
    other = start_supervised!(RecordingTransport, id: :other_transport)

    targets =
      c.targets ++ [%{host: :other@local, transport: RecordingTransport, handle: RecordingTransport.endpoint(other)}]

    assert :ok = Bridge.set_targets(c.bridge, targets)
    :ok = RecordingTransport.mode(c.transport, {:error, :noconnect})
    assert {:ok, %{targets: [:interested@local, :other@local]}} = Bridge.publish(c.endpoint, c.signal)
    eventually(fn -> Bridge.status(c.bridge).in_flight == 0 end)
    assert %{appended: 1, rejected: 1, health: :degraded} = Bridge.status(c.bridge)
    assert [_] = RecordingTransport.exports(c.transport)
    assert [_] = RecordingTransport.exports(other)
  end

  test "bridge shutdown closes admission and confirms owned task exit", c do
    :ok = RecordingTransport.hold(c.transport)
    assert {:ok, _} = Bridge.publish(c.endpoint, c.signal)
    eventually(fn -> RecordingTransport.pending(c.transport) == 1 end)
    [worker] = RecordingTransport.callers(c.transport)
    monitor = Process.monitor(worker)
    assert :ok = stop_supervised(Bridge)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert {:error, :closed} = Bridge.publish(c.endpoint, c.signal)
    assert Process.alive?(c.bus)
    assert :ok = RecordingTransport.release(c.transport, {:error, :closed})
  end
end
