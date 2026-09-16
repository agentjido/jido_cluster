defmodule JidoCluster.JournalMnesiaTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster.Journal
  alias Jido.Persistence.Mnesia
  alias JidoCluster.Test.{JournalContract, JournalService, JournalSnapshot}

  test "the shared record contract uses real Mnesia transactions and isolated keys" do
    table = __MODULE__
    assert {:atomic, :ok} = :mnesia.create_table(table, attributes: [:key, :value], ram_copies: [node()])
    on_exit(fn -> assert {:atomic, :ok} = :mnesia.delete_table(table) end)
    :ok = Mnesia.put("jido:agent:unrelated", "unchanged", table: table)
    result = JournalContract.exercise({Mnesia, table: table}, {"mnesia-journal", "scope"})
    aggregate = JournalSnapshot.exercise({Mnesia, table: table})
    assert aggregate.bytes < Journal.limits().admission_bytes
    assert :ok = JournalService.exercise({Mnesia, table: table})
    assert :ok = JidoCluster.Test.Federation.JournalContract.exercise({Mnesia, table: table})
    assert %{bindings: 64} = JidoCluster.Test.Federation.JournalContract.exercise_bound({Mnesia, table: table})
    assert {:ok, "unchanged"} = Mnesia.get("jido:agent:unrelated", table: table)
    assert {:ok, bytes} = Mnesia.get(result.journal.key, table: table)
    assert byte_size(bytes) < Journal.limits().record_bytes
  end
end
