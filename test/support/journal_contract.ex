defmodule JidoCluster.Test.JournalContract do
  @moduledoc false
  import ExUnit.Assertions
  alias Jido.Cluster.Journal

  def exercise(adapter, scope) do
    {:ok, first} = Journal.open(adapter, scope)
    {:ok, competitor} = Journal.open(adapter, scope)
    assert {:ok, saved} = Journal.commit(first, %{"request" => "one", "desired" => "running", "count" => 0})
    assert {:error, :conflict, blocked} = Journal.commit(competitor, %{"request" => "other"})
    assert {:error, :reconciliation_required, ^blocked} = Journal.commit(blocked, %{})
    {:ok, restored} = Journal.reload(blocked)
    assert restored.record == saved.record

    {elapsed, final} =
      :timer.tc(fn ->
        Enum.reduce(1..25, restored, fn n, journal ->
          assert {:ok, next} = Journal.commit(journal, Map.put(journal.record, "count", n))
          assert next.revision == journal.revision + 1
          next
        end)
      end)

    assert {:ok, reread} = Journal.open(adapter, scope)
    assert reread.record["count"] == 25
    assert reread.revision == 26
    assert reread.write_id == final.write_id
    {namespace, name} = scope
    {:ok, other} = Journal.open(adapter, {namespace, name <> "/other"})
    assert other.record == nil

    assert {:error, {:record_too_large, _, _}, ^reread} =
             Journal.commit(reread, %{"huge" => String.duplicate("x", Journal.limits().record_bytes)})

    {:ok, unchanged} = Journal.reload(reread)
    assert unchanged.revision == 26
    %{journal: final, write_microseconds: elapsed, writes: 25}
  end
end
