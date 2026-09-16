defmodule JidoCluster.JournalTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster.Journal
  alias JidoCluster.Test.JournalAdapter
  alias JidoCluster.Test.JournalContract

  setup do
    server = start_supervised!({JournalAdapter, []})
    adapter = {JournalAdapter, server: server}
    {:ok, journal} = Journal.open(adapter, {"journal-test", "scope"})
    %{server: server, adapter: adapter, journal: journal}
  end

  test "the shared record contract also runs with the controlled adapter", c do
    result = JournalContract.exercise(c.adapter, {"shared-contract", "scope"})
    assert result.journal.revision == 26
  end

  test "CAS revisions survive a fresh handle and scope keys stay separate", c do
    assert c.journal.record == nil
    assert {:ok, saved} = Journal.commit(c.journal, %{"desired" => "running"})
    assert saved.revision == 1
    assert {:ok, recovered} = Journal.open(c.adapter, {"journal-test", "scope"})
    assert recovered.record == saved.record
    assert recovered.revision == 1
    assert {:ok, next} = Journal.commit(recovered, %{"desired" => "stopped"})
    assert next.revision == 2
    assert {:ok, other} = Journal.open(c.adapter, {"journal-test", "other"})
    assert other.record == nil
    refute other.key == next.key
    assert String.starts_with?(next.key, "jido:cluster:journal:v1:")
    refute String.starts_with?(next.key, "jido:agent:")
  end

  test "a stale handle cannot overwrite another revision", c do
    {:ok, saved} = Journal.commit(c.journal, %{"winner" => true})
    assert {:error, :conflict, blocked} = Journal.commit(c.journal, %{"winner" => false})
    assert {:error, :reconciliation_required, ^blocked} = Journal.commit(blocked, %{})
    assert {:ok, current} = Journal.reload(blocked)
    assert current.record == saved.record
    assert {:ok, fenced} = Journal.commit(current, current.record)
    assert fenced.revision == saved.revision + 1
    assert fenced.write_id != saved.write_id
  end

  test "a committed write with a lost reply is discovered without a second write", c do
    :ok = JournalAdapter.mode(c.server, :commit_then_lose)
    record = %{"request_id" => "original", "operation_id" => "one"}
    assert {:error, {:indeterminate, :timeout}, blocked} = Journal.commit(c.journal, record)
    assert {:error, :reconciliation_required, ^blocked} = Journal.commit(blocked, %{})
    assert {:ok, current} = Journal.reload(blocked)
    assert current.record == record
    assert current.revision == 1
    assert length(JournalAdapter.writes(c.server)) == 1
  end

  test "a token from one read is used as the next CAS condition" do
    server = start_supervised!({JournalAdapter, tokens: true}, id: :tokens)
    adapter = {JournalAdapter, server: server}
    {:ok, initial} = Journal.open(adapter, {"tokens", "scope"})
    {:ok, _} = Journal.commit(initial, %{"n" => 1})
    {:ok, read} = Journal.open(adapter, {"tokens", "scope"})
    assert {:token, token} = read.expected
    assert {:ok, _} = Journal.commit(read, %{"n" => 2})
    assert [{_, :not_found, _}, {_, {:token, ^token}, _}] = JournalAdapter.writes(server)
  end

  test "a recovery CAS prevents a delayed old write from taking effect", c do
    :ok = JournalAdapter.mode(c.server, :delay)
    {:error, {:indeterminate, :timeout}, blocked} = Journal.commit(c.journal, %{"late" => true})
    {:ok, observed} = Journal.reload(blocked)
    assert observed.record == nil
    # A read alone cannot settle the outstanding write. This confirmed revision
    # precedes any recovery effect and defeats its old comparison condition.
    assert {:ok, recovered} = Journal.commit(observed, %{"recovery" => true})
    assert {:error, :conflict} = JournalAdapter.finish_delayed(c.server)
    assert {:ok, current} = Journal.reload(recovered)
    assert current.record == %{"recovery" => true}
  end

  test "only explicit pre-write rejection leaves the handle writable", c do
    :ok = JournalAdapter.mode(c.server, {:return, {:error, {:rejected, :offline_before_write}}})
    assert {:error, {:rejected, :offline_before_write}, same} = Journal.commit(c.journal, %{})
    assert same == c.journal
    assert {:ok, _} = Journal.commit(same, %{})
  end

  for result <- [{:error, :offline}, {:raise, "failed"}, {:throw, :lost}, {:exit, :lost}, :invalid] do
    test "unknown adapter result #{inspect(result)} blocks the handle", c do
      :ok = JournalAdapter.mode(c.server, {:return, unquote(Macro.escape(result))})
      assert {:error, {:indeterminate, _}, blocked} = Journal.commit(c.journal, %{})
      assert {:error, :reconciliation_required, ^blocked} = Journal.commit(blocked, %{})
    end
  end

  test "runtime values and oversized records fail before storage", c do
    for value <- [self(), make_ref(), fn -> :ok end, :module_atom, {"tuple"}, %{atom_key: 1}] do
      assert {:error, {:invalid_record, _}, _} = Journal.commit(c.journal, %{"invalid" => value})
    end

    record = %{"large" => String.duplicate("x", Journal.limits().record_bytes)}
    assert {:error, {:record_too_large, _, _}, _} = Journal.commit(c.journal, record)
    assert JournalAdapter.writes(c.server) == []
  end

  test "unknown schema and wrong scope fail on read", c do
    {:ok, saved} = Journal.commit(c.journal, %{})
    [{key, _, bytes}] = JournalAdapter.writes(c.server)
    document = Jason.decode!(bytes)

    for changed <- [Map.put(document, "version", 999), Map.put(document, "scope", "other")] do
      assert :ok = JournalAdapter.compare_and_swap(key, saved.expected, Jason.encode!(changed), server: c.server)
      assert {:error, _} = Journal.open(c.adapter, {"journal-test", "scope"})
      :ok = JournalAdapter.compare_and_swap(key, Jason.encode!(changed), bytes, server: c.server)
    end
  end

  test "a known committed revision cannot move backward or change identity", c do
    {:ok, first} = Journal.commit(c.journal, %{"n" => 1})
    {:ok, second} = Journal.commit(first, %{"n" => 2})
    assert :ok = JournalAdapter.compare_and_swap(second.key, second.expected, first.expected, server: c.server)
    assert {:error, {:invalid_journal_record, :revision_regressed}} = Journal.reload(second)
    changed = second.expected |> Jason.decode!() |> Map.put("write_id", Jido.generate_id()) |> Jason.encode!()
    assert :ok = JournalAdapter.compare_and_swap(second.key, first.expected, changed, server: c.server)
    assert {:error, {:invalid_journal_record, :revision_changed}} = Journal.reload(second)
    changed_record = second.expected |> Jason.decode!() |> Map.put("record", %{"n" => 2.0}) |> Jason.encode!()
    assert :ok = JournalAdapter.compare_and_swap(second.key, changed, changed_record, server: c.server)
    assert {:error, {:invalid_journal_record, :revision_changed}} = Journal.reload(second)
  end
end
