defmodule JidoCluster.Examples.UncertainJournalSourceTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.JournalRecoveryCase
  alias Jido.Cluster.Examples.UncertainJournalSource
  alias JidoCluster.Examples.Support.JournalReplyLoss

  @tag cluster_nodes: 3, tmp_dir: true, timeout: 120_000
  test "a disconnected live source stays uncertain after journaled restart", context do
    c = start(context, UncertainJournalSource, :bedrock, lost_reply: true)
    [source, target] = c.workers
    deployed = deploy(c, selected_on(c, UncertainJournalSource, "source", source))
    work(c, deployed, 1)
    token = api(c, :request_id)

    # The real journal commits admission before this test disconnects the source.
    assert :ok = cluster_call(c.cluster, c.control, JournalReplyLoss, :hold_next, [c.faults])
    assert {:ok, _} = cluster_call(c.cluster, c.control, JournalReplyLoss, :start_drain, [c.service, source, token])
    eventually(fn -> cluster_call(c.cluster, c.control, JournalReplyLoss, :waiting, [c.faults]) end)
    cookie = cluster_call(c.cluster, c.control, Node, :get_cookie, [])
    on_exit(fn -> reconnect(c, source, cookie) end)
    disconnect(c, source)
    assert cluster_call(c.cluster, source, Process, :alive?, [deployed.agent])
    assert :ok = cluster_call(c.cluster, c.control, JournalReplyLoss, :release, [c.faults])
    {:ok, drain} = api(c, :drain, [source, [request_id: token]])
    assert {:ok, %{phase: :uncertain}} = api(c, :await, [drain.id, 20_000])

    c = restart(c)
    recover(c)
    refute source in cluster_call(c.cluster, c.control, Node, :list, [])
    assert {:ok, %{id: same, phase: :uncertain}} = api(c, :drain, [source, [request_id: token]])
    assert same == drain.id
    assert {:error, :uncertain} = api(c, :lookup, [deployed.ref])
    assert Enum.sort(Enum.map(api(c, :claims), & &1.host)) == Enum.sort([source, target])
    assert Enum.all?(api(c, :claims), &(&1.state == :uncertain))

    assert %{active: 0} =
             cluster_call(c.cluster, target, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(c.jido)])

    # Reconnect only after the uncertain result is proved. This permits checked cleanup.
    reconnect(c, source, cookie)
    recover(c)
    result = api(c, :operation, [drain.id])
    assert match?({:ok, %{phase: :completed}}, result), inspect({result, api(c, :status, [deployed.topology.id])})
    assert node(count(c, deployed.ref, 1)) == target
    cleanup(c)
  end

  defp disconnect(c, source) do
    for peer <- c.cluster.nodes -- [source] do
      assert true = cluster_call(c.cluster, peer, Node, :set_cookie, [source, :journal_partition_control])
      assert true = cluster_call(c.cluster, source, Node, :set_cookie, [peer, :journal_partition_source])
    end

    for peer <- c.cluster.nodes -- [source] do
      cluster_call(c.cluster, peer, Node, :disconnect, [source])
    end

    [first, second] = c.cluster.nodes -- [source]
    assert true = cluster_call(c.cluster, first, Node, :connect, [second])

    eventually(fn ->
      Enum.all?(c.cluster.nodes -- [source], fn peer ->
        source not in cluster_call(c.cluster, peer, Node, :list, [])
      end)
    end)
  end

  defp reconnect(c, source, cookie) do
    for peer <- c.cluster.nodes -- [source] do
      assert true = cluster_call(c.cluster, peer, Node, :set_cookie, [source, cookie])
      assert true = cluster_call(c.cluster, source, Node, :set_cookie, [peer, cookie])
      assert true = cluster_call(c.cluster, peer, Node, :connect, [source])
    end

    eventually(fn ->
      Enum.all?(c.cluster.nodes, fn peer ->
        Enum.sort(cluster_call(c.cluster, peer, Node, :list, [])) == Enum.sort(c.cluster.nodes -- [peer])
      end)
    end)
  end
end
