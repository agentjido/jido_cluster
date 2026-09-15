defmodule JidoCluster.Storage.MnesiaAdapterTest do
  use ExUnit.Case, async: false

  alias JidoCluster.Storage.Mnesia

  defp unique_table(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  test "checkpoint operations" do
    opts = [table: unique_table(:jc_mnesia_cp)]
    key = {:agent, "abc"}
    data = %{counter: 12}

    assert :not_found = Mnesia.get_checkpoint(key, opts)
    assert :ok = Mnesia.put_checkpoint(key, data, opts)
    assert {:ok, ^data} = Mnesia.get_checkpoint(key, opts)
    assert :ok = Mnesia.delete_checkpoint(key, opts)
    assert :not_found = Mnesia.get_checkpoint(key, opts)
  end

  test "append/load/delete thread" do
    opts = [table: unique_table(:jc_mnesia_thread)]
    thread_id = "thread-#{System.unique_integer([:positive])}"

    assert {:ok, thread} = Mnesia.append_thread(thread_id, [%{kind: :note, payload: %{x: 1}}], opts)
    assert thread.rev == 1

    assert {:ok, loaded} = Mnesia.load_thread(thread_id, opts)
    assert loaded.rev == 1

    assert :ok = Mnesia.delete_thread(thread_id, opts)
    assert :not_found = Mnesia.load_thread(thread_id, opts)
  end

  test "expected_rev conflict" do
    opts = [table: unique_table(:jc_mnesia_rev)]
    thread_id = "thread-#{System.unique_integer([:positive])}"

    assert {:ok, _thread} =
             Mnesia.append_thread(thread_id, [%{kind: :note, payload: %{a: 1}}], Keyword.put(opts, :expected_rev, 0))

    assert {:error, :conflict} =
             Mnesia.append_thread(thread_id, [%{kind: :note, payload: %{a: 2}}], Keyword.put(opts, :expected_rev, 0))
  end
end
