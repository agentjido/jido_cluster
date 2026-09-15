defmodule JidoCluster.Storage.MnesiaAdapterTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster.Storage.Mnesia

  setup do
    table = :"v3_mnesia_#{System.unique_integer([:positive])}"
    assert {:atomic, :ok} = :mnesia.create_table(table, attributes: [:key, :value], ram_copies: [node()])
    on_exit(fn -> :mnesia.delete_table(table) end)
    %{opts: [table: table]}
  end

  test "byte operations implement the V3 adapter contract", %{opts: opts} do
    assert :ok = Mnesia.validate_options(opts)
    assert {:error, :not_found} = Mnesia.get("one", opts)
    assert :ok = Mnesia.compare_and_swap("one", :not_found, "first", opts)
    assert {:ok, "first"} = Mnesia.get("one", opts)
    assert {:error, :conflict} = Mnesia.compare_and_swap("one", "stale", "second", opts)
    assert {:ok, "first"} = Mnesia.get("one", opts)
    assert :ok = Mnesia.compare_and_swap("one", "first", "second", opts)
    assert :ok = Mnesia.put("one", "maintenance", opts)
    assert {:ok, "maintenance"} = Mnesia.get("one", opts)
    assert :ok = Mnesia.delete("one", opts)
    assert {:error, :not_found} = Mnesia.get("one", opts)
  end

  test "only one concurrent create can succeed", %{opts: opts} do
    results =
      ["a", "b"]
      |> Task.async_stream(&Mnesia.compare_and_swap("race", :not_found, &1, opts))
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.sort(results) == Enum.sort([:ok, {:error, :conflict}])
    assert {:ok, value} = Mnesia.get("race", opts)
    assert value in ["a", "b"]
  end

  test "the application must create its table before adapter use" do
    table = :"missing_v3_#{System.unique_integer([:positive])}"
    assert {:error, _} = Mnesia.validate_options(table: table)
    assert {:error, _} = Mnesia.put("one", "value", table: table)
    refute table in :mnesia.system_info(:tables)
  end

  test "node-local tables are rejected" do
    table = :"local_v3_#{System.unique_integer([:positive])}"
    assert {:atomic, :ok} = :mnesia.create_table(table, attributes: [:key, :value], local_content: true)
    on_exit(fn -> :mnesia.delete_table(table) end)
    assert {:error, :invalid_mnesia_options} = Mnesia.validate_options(table: table)
  end

  test "a nested transaction cannot report a write before its outer commit", %{opts: opts} do
    assert {:atomic, {:error, {:rejected, :nested_transaction}}} =
             :mnesia.transaction(fn -> Mnesia.compare_and_swap("nested", :not_found, "value", opts) end)

    assert {:error, :not_found} = Mnesia.get("nested", opts)
  end
end
