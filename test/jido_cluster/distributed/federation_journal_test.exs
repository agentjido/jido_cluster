defmodule JidoCluster.Distributed.FederationJournalTest do
  use JidoCluster.Test.ClusterCase
  alias JidoCluster.Test.Bedrock
  alias JidoCluster.Test.Federation.JournalContract

  @tag cluster_nodes: 1, tmp_dir: true, timeout: 90_000
  test "real Bedrock restores declared bindings after Repo and managed Core restart", c do
    [host] = c.cluster.nodes

    on_exit(fn ->
      stop_node(c.cluster, host)
      File.rm_rf!(c.tmp_dir)
    end)

    assert {:ok, _} = cluster_call(c.cluster, host, Bedrock, :start, [c.tmp_dir], 40_000)
    adapter = {Jido.Persistence.Bedrock, repo: Bedrock.Repo}
    assert :ok = cluster_call(c.cluster, host, JournalContract, :exercise, [adapter, Bedrock], 40_000)

    assert %{bindings: 64, bytes: bytes} =
             cluster_call(c.cluster, host, JournalContract, :exercise_bound, [adapter], 30_000)

    IO.puts("Bedrock federation: 64 live bindings, #{bytes} journal bytes")
    assert :ok = cluster_call(c.cluster, host, Bedrock, :stop, [])
  end
end
