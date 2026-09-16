defmodule JidoCluster.Distributed.JournalBedrockTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster.Journal
  alias JidoCluster.Test.{Bedrock, JournalContract, JournalService, JournalSnapshot}

  @tag cluster_nodes: 1, tmp_dir: true, timeout: 90_000
  test "real Bedrock runs the record contract and restores it after repository restart", c do
    [host] = c.cluster.nodes

    on_exit(fn ->
      stop_node(c.cluster, host)
      File.rm_rf!(c.tmp_dir)
    end)

    assert {:ok, _} = cluster_call(c.cluster, host, Bedrock, :start, [c.tmp_dir], 40_000)
    adapter = {Jido.Persistence.Bedrock, repo: Bedrock.Repo}

    assert :ok =
             cluster_call(c.cluster, host, Jido.Persistence.Bedrock, :put, [
               "jido:agent:unrelated",
               "unchanged",
               [repo: Bedrock.Repo]
             ])

    result = cluster_call(c.cluster, host, JournalContract, :exercise, [adapter, {"real-bedrock", "scope"}], 30_000)
    assert result.journal.revision == 26
    aggregate = cluster_call(c.cluster, host, JournalSnapshot, :exercise, [adapter], 30_000)
    assert aggregate.bytes < Journal.limits().admission_bytes
    assert {:ok, _} = cluster_call(c.cluster, host, Bedrock, :restart, [], 40_000)
    assert {:ok, restored} = cluster_call(c.cluster, host, Journal, :open, [adapter, {"real-bedrock", "scope"}])
    assert restored.record == result.journal.record
    assert restored.revision == result.journal.revision

    assert {:ok, restored_aggregate} =
             cluster_call(c.cluster, host, Journal, :open, [adapter, {"aggregate-contract", "scope"}])

    assert restored_aggregate.record == aggregate.journal.record
    assert restored_aggregate.revision == 25
    assert :ok = cluster_call(c.cluster, host, JournalService, :exercise, [adapter], 30_000)
    assert :ok = cluster_call(c.cluster, host, JournalService, :exercise_outage, [adapter, Bedrock], 30_000)

    assert {:ok, "unchanged"} =
             cluster_call(c.cluster, host, Jido.Persistence.Bedrock, :get, [
               "jido:agent:unrelated",
               [repo: Bedrock.Repo]
             ])

    assert :ok = cluster_call(c.cluster, host, Bedrock, :stop, [])
    IO.puts("Bedrock journal: #{result.writes} CAS writes in #{result.write_microseconds} microseconds")

    IO.puts(
      "Bedrock aggregate: #{aggregate.bytes} bytes, #{aggregate.writes} CAS writes in #{aggregate.write_microseconds} microseconds"
    )
  end
end
