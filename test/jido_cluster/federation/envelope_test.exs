defmodule JidoCluster.Federation.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Jido.Cluster.Federation.{Envelope, Limits}

  @scope {"north", "orders/one", "events"}

  test "one-hop envelopes preserve every original Signal field and a distinct export identity" do
    signal = signal()
    assert {:ok, limits} = Limits.new([])
    assert {:ok, first} = Envelope.new(@scope, "origin-generation", signal, limits)
    assert {:ok, second} = Envelope.new(@scope, "origin-generation", signal, limits)
    assert first.signal === signal
    assert first.hops == 1
    refute first.export_id == second.export_id
    assert Envelope.identity(first) == {"origin-generation", first.export_id}
    assert {:ok, ^signal} = Envelope.validate(first, @scope, [signal.type], limits)
  end

  test "scope, type, generation, hop, and malformed Signal checks reject without rewriting" do
    assert {:ok, limits} = Limits.new([])
    assert {:ok, envelope} = Envelope.new(@scope, "generation", signal(), limits)

    assert {:error, :invalid_envelope_scope} =
             Envelope.validate(envelope, {"south", "orders/one", "events"}, ["order.changed"], limits)

    assert {:error, :type_not_allowed} = Envelope.validate(envelope, @scope, ["order.removed"], limits)

    for changed <- [
          Map.put(envelope, :extra, self()),
          %{envelope | generation: ""},
          %{envelope | export_id: ""},
          %{envelope | hops: 0},
          %{envelope | hops: 2},
          %{envelope | signal: %{envelope.signal | id: nil}},
          %{envelope | signal: %{envelope.signal | extensions: %{bad: self()}}}
        ] do
      assert {:error, _} = Envelope.validate(changed, @scope, ["order.changed"], limits)
    end
  end

  test "runtime payload values and oversized encoded envelopes are rejected before admission" do
    assert {:ok, limits} = Limits.new(max_envelope_bytes: 1024)

    for data <- [self(), fn -> :ok end, make_ref(), %{nested: [self()]}] do
      assert {:error, :non_portable_signal} = Envelope.new(@scope, "generation", %{signal() | data: data}, limits)
    end

    assert {:error, :envelope_too_large} =
             Envelope.new(@scope, "generation", %{signal() | data: String.duplicate("x", 1024)}, limits)

    assert {:ok, envelope} = Envelope.new(@scope, "generation", signal(), limits)
    assert Envelope.bytes(envelope) <= limits.max_envelope_bytes
    oversized = %{envelope | signal: %{envelope.signal | data: String.duplicate("x", 1024)}}
    assert {:error, :envelope_too_large} = Envelope.validate(oversized, @scope, ["order.changed"], limits)
  end

  test "limits validate queue, fanout, and cache bounds without optional dependencies" do
    assert {:ok, limits} = Limits.new([])
    assert limits.max_envelope_bytes == 16_384
    assert limits.outbound_slots == 32
    assert limits.inbound_slots == 32
    assert limits.outbound_bytes == 524_288
    assert limits.inbound_bytes == 524_288
    assert limits.max_hosts == 32
    assert limits.dedup_entries == 1024
    assert limits.dedup_ttl_ms == 60_000

    for options <- [
          [unknown: 1],
          [outbound_slots: 0],
          [inbound_slots: :infinity],
          [max_hosts: 33],
          [max_envelope_bytes: 65_537],
          [dedup_entries: 0],
          [dedup_ttl_ms: -1],
          [outbound_bytes: 100],
          [inbound_bytes: 100],
          [outbound_slots: 1, outbound_slots: 2]
        ] do
      assert {:error, :invalid_federation_limits} = Limits.new(options)
    end
  end

  defp signal do
    Jido.Signal.new!(%{
      id: "original-id",
      type: "order.changed",
      source: "/orders/source",
      subject: "order-17",
      time: "2026-09-15T00:00:00Z",
      data: %{count: 3, raw: <<255>>},
      extensions: %{"trace" => "original"}
    })
  end
end
