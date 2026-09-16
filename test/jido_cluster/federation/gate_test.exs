defmodule JidoCluster.Federation.GateTest do
  use ExUnit.Case, async: true

  alias Jido.Cluster.Federation.{Gate, Limits}

  test "concurrent callers reserve fixed slots before any mailbox submission" do
    {:ok, limits} = Limits.new(outbound_slots: 4, outbound_bytes: 4096, max_envelope_bytes: 1024)
    gate = Gate.new(limits, :outbound)
    tasks = for _ <- 1..128, do: Task.async(fn -> Gate.reserve(gate, 128) end)
    results = Task.await_many(tasks)
    accepted = for {:ok, permit} <- results, do: permit
    assert length(accepted) == 4
    assert Enum.count(results, &(&1 == {:error, :capacity})) == 124
    assert %{used_slots: 4, reserved_bytes: 4096, payload_bytes: 512} = Gate.status(gate)
    assert {:error, :capacity} = Gate.reserve(gate, 128)

    for permit <- accepted, do: assert(:ok = Gate.release(gate, permit))
    assert %{used_slots: 0, reserved_bytes: 0, payload_bytes: 0} = Gate.status(gate)
    assert :ok = Gate.close(gate)
  end

  test "a byte budget rounds down to complete maximum-sized slots" do
    {:ok, limits} = Limits.new(inbound_slots: 10, inbound_bytes: 2500, max_envelope_bytes: 1024)
    gate = Gate.new(limits, :inbound)
    assert %{slot_limit: 2, byte_limit: 2500} = Gate.status(gate)
    assert {:ok, first} = Gate.reserve(gate, 1)
    assert {:ok, second} = Gate.reserve(gate, 1024)
    assert {:error, :capacity} = Gate.reserve(gate, 1)
    assert %{reserved_bytes: 2048, payload_bytes: 1025} = Gate.status(gate)
    assert :ok = Gate.release(gate, first)
    assert :ok = Gate.release(gate, second)
    assert :ok = Gate.close(gate)
  end

  test "oversized input does not take capacity and stale release cannot free a reused slot" do
    {:ok, limits} = Limits.new(outbound_slots: 1, max_envelope_bytes: 1024)
    gate = Gate.new(limits, :outbound)
    assert {:error, :envelope_too_large} = Gate.reserve(gate, 1025)
    assert {:error, :invalid_size} = Gate.reserve(gate, 0)
    assert {:ok, first} = Gate.reserve(gate, 32)
    assert :ok = Gate.release(gate, first)
    assert {:ok, second} = Gate.reserve(gate, 64)
    refute first == second
    assert {:error, :stale_permit} = Gate.release(gate, first)
    assert %{used_slots: 1, payload_bytes: 64} = Gate.status(gate)
    assert :ok = Gate.release(gate, second)
    assert :ok = Gate.close(gate)
    assert {:error, :closed} = Gate.reserve(gate, 1)
  end

  test "caller exit does not reopen a slot whose message could still be queued" do
    {:ok, limits} = Limits.new(outbound_slots: 1)
    gate = Gate.new(limits, :outbound)
    task = Task.async(fn -> Gate.reserve(gate, 1) end)
    assert {:ok, permit} = Task.await(task)
    refute Process.alive?(task.pid)
    assert {:error, :capacity} = Gate.reserve(gate, 1)
    assert :ok = Gate.release(gate, permit)
    assert :ok = Gate.close(gate)
  end

  test "owner exit closes its admission generation and stale handles fail closed" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, limits} = Limits.new([])
        send(parent, {:gate, Gate.new(limits, :inbound)})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      cleanup = Process.monitor(pid)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      assert_receive {:DOWN, ^cleanup, :process, ^pid, _}
    end)

    assert_receive {:gate, gate}
    assert {:ok, permit} = Gate.reserve(gate, 1)
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert {:error, :closed} = Gate.reserve(gate, 1)
    assert {:error, :closed} = Gate.release(gate, permit)
    assert {:error, :closed} = Gate.status(gate)
  end
end
