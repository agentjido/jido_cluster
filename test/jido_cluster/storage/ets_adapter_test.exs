defmodule JidoCluster.Storage.ETSAdapterTest do
  use ExUnit.Case, async: true

  alias JidoCluster.Storage.ETS

  defp unique_table(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  test "checkpoint operations" do
    opts = [table: unique_table(:jc_ets_cp)]
    key = {:agent, "1"}
    data = %{foo: "bar"}

    assert :not_found = ETS.get_checkpoint(key, opts)
    assert :ok = ETS.put_checkpoint(key, data, opts)
    assert {:ok, ^data} = ETS.get_checkpoint(key, opts)
    assert :ok = ETS.delete_checkpoint(key, opts)
    assert :not_found = ETS.get_checkpoint(key, opts)
  end

  test "thread operations with expected_rev" do
    opts = [table: unique_table(:jc_ets_thread)]
    thread_id = "thread-#{System.unique_integer([:positive])}"

    assert {:ok, t1} = ETS.append_thread(thread_id, [%{kind: :note, payload: %{a: 1}}], opts)
    assert t1.rev == 1

    assert {:error, :conflict} =
             ETS.append_thread(thread_id, [%{kind: :note, payload: %{a: 2}}], Keyword.put(opts, :expected_rev, 0))

    assert {:ok, t2} =
             ETS.append_thread(thread_id, [%{kind: :note, payload: %{a: 2}}], Keyword.put(opts, :expected_rev, 1))

    assert t2.rev == 2
    assert {:ok, loaded} = ETS.load_thread(thread_id, opts)
    assert loaded.rev == 2

    assert :ok = ETS.delete_thread(thread_id, opts)
    assert :not_found = ETS.load_thread(thread_id, opts)
  end
end
