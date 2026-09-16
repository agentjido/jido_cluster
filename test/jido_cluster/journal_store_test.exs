defmodule JidoCluster.JournalStoreTest do
  use ExUnit.Case, async: false

  alias Jido.Cluster.Journal
  alias Jido.Error.ExecutionError
  alias JidoCluster.Test.JournalAdapter

  defmodule ReadAdapter do
    @moduledoc false
    @behaviour Jido.Persistence.Adapter

    @impl true
    def get(_key, opts), do: Keyword.fetch!(opts, :read).()

    @impl true
    def compare_and_swap(_, _, _, _), do: raise("a read must not write")
  end

  setup do
    server = start_supervised!({JournalAdapter, []})
    {:ok, journal} = Journal.open({JournalAdapter, server: server}, {"store-contract", "scope"})
    %{server: server, journal: journal}
  end

  test "journal reads and writes use core Store telemetry without exposing the record", c do
    handler = {__MODULE__, make_ref()}
    observer = self()

    :ok =
      :telemetry.attach(
        handler,
        [:jido, :persistence, :store, :stop],
        fn _, _, metadata, _ ->
          if self() == observer, do: send(observer, {:store_completed, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, saved} = Journal.commit(c.journal, %{"secret-payload" => "sensitive-value"})

    assert_received {:store_completed,
                     %{operation: :compare_and_swap, adapter_module: JournalAdapter, status: :ok} = write}

    assert {:ok, recovered} = Journal.reload(saved)
    assert recovered.record == saved.record
    assert_received {:store_completed, %{operation: :load, adapter_module: JournalAdapter, status: :ok} = read}

    for metadata <- [read, write] do
      refute inspect(metadata) =~ "sensitive-value"
      refute inspect(metadata) =~ saved.key
      for key <- [:key, :value, :token, :options], do: refute(Map.has_key?(metadata, key))
    end
  end

  test "plain indeterminate writes retain their outcome and require recovery", c do
    # The adapter commits, then loses the result. Neither Store nor Journal may
    # replay the write. A later read discovers the one committed revision.
    :ok = JournalAdapter.mode(c.server, :commit_then_indeterminate)
    assert {:error, :indeterminate, blocked} = Journal.commit(c.journal, %{"intent" => "running"})
    assert blocked.status == :uncertain
    assert {:error, :reconciliation_required, ^blocked} = Journal.commit(blocked, %{})
    assert {:ok, restored} = Journal.reload(blocked)
    assert restored.record == %{"intent" => "running"}
    assert restored.revision == 1
    assert length(JournalAdapter.writes(c.server)) == 1
  end

  test "malformed reads use the shared Store error contract", c do
    {:ok, saved} = Journal.commit(c.journal, %{})

    for result <- [{:ok, saved.expected, ""}, {:ok, :not_bytes}, :invalid] do
      adapter = {ReadAdapter, read: fn -> result end}

      assert {:error, {:journal_read_failed, %ExecutionError{details: details}}} =
               Journal.open(adapter, {"store-contract", "scope"})

      assert details.code == :persistence_invalid_callback_result
    end
  end

  test "read callback faults are contained by core Store" do
    for read <- [fn -> raise "read failed" end, fn -> throw(:read_failed) end, fn -> exit(:read_failed) end] do
      assert {:error, {:journal_read_failed, %ExecutionError{details: details}}} =
               Journal.open({ReadAdapter, read: read}, {"store-contract", "scope"})

      assert details.code == :persistence_callback_failed
      assert details.operation == :get
    end
  end

  test "the journal keeps the exact read bytes as the next write condition", c do
    {:ok, saved} = Journal.commit(c.journal, %{"n" => 1})
    pretty = saved.expected |> Jason.decode!() |> Jason.encode!(pretty: true)
    refute pretty == saved.expected
    assert :ok = JournalAdapter.compare_and_swap(saved.key, saved.expected, pretty, server: c.server)
    assert {:ok, reloaded} = Journal.reload(saved)
    assert reloaded.expected == pretty
    assert reloaded.record == saved.record
    assert {:ok, next} = Journal.commit(reloaded, %{"n" => 2})
    assert next.revision == 2
    assert {_, ^pretty, _} = List.last(JournalAdapter.writes(c.server))
  end

  test "a durable journal rejects an unconfigured byte store" do
    assert {:error, :persistence_not_configured} = Journal.open(nil, {"store-contract", "scope"})
  end
end
