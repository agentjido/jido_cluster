defmodule JidoCluster.Examples.UnknownJournalWriteTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.JournalRecoveryCase
  alias Jido.Cluster.{Examples.UnknownJournalWrite, Journal}
  alias JidoCluster.Examples.Support.JournalReplyLoss

  @tag cluster_nodes: 2, tmp_dir: true, timeout: 90_000
  test "a real Bedrock commit with a lost reply retains the original request", context do
    c = start(context, UnknownJournalWrite, :bedrock, lost_reply: true)
    topology = UnknownJournalWrite.new!(id: "lost-reply")
    token = api(c, :request_id)
    assert :ok = cluster_call(c.cluster, c.control, JournalReplyLoss, :lose_next, [c.faults])
    assert {:error, {:journal_write_failed, _}} = api(c, :deploy, [topology, [request_id: token]])
    assert %{status: :journal_unavailable} = api(c, :status)
    {:ok, stored} = cluster_call(c.cluster, c.control, Journal, :open, [c.adapter, {c.namespace, "default"}])
    assert [%{"nonce" => nonce, "operation" => operation}] = stored.record["requests"]
    assert nonce == token.nonce

    for host <- c.workers do
      assert %{active: 0} =
               cluster_call(c.cluster, host, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(c.jido)])
    end

    c = restart(c)
    recover(c)
    assert {:ok, %{id: ^operation, phase: :completed}} = api(c, :deploy, [topology, [request_id: token]])
    assert [_] = api(c, :claims)
    {:ok, ref} = api(c, :ref, [topology.id, :worker])
    agent = count(c, ref, 0)
    assert {:ok, %{id: ^operation}} = api(c, :deploy, [topology, [request_id: token]])
    assert {:ok, %{pid: ^agent}} = api(c, :lookup, [ref])
    cleanup(c)
  end
end
