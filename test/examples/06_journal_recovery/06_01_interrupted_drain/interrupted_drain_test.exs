defmodule JidoCluster.Examples.InterruptedDrainTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.JournalRecoveryCase
  alias Jido.Cluster.Examples.InterruptedDrain
  alias Jido.Cluster.Journal
  alias JidoCluster.Examples.Support.JournalReplyLoss

  @tag cluster_nodes: 3, tmp_dir: true, timeout: 90_000
  test "Bedrock retains a partially completed drain across coordinator death", context do
    c = start(context, InterruptedDrain, :bedrock, lost_reply: true)
    [source, target] = c.workers

    workers =
      for count <- 1..2 do
        deployed = deploy(c, selected_on(c, InterruptedDrain, "worker-#{count}", source))
        work(c, deployed, count)
        {deployed, count}
      end

    barrier = barrier(c)
    token = api(c, :request_id)
    {:ok, drain} = api(c, :drain, [source, [request_id: token]])
    eventually(fn -> waiting(c) != [] end)
    assert :ok = cluster_call(c.cluster, c.control, JournalReplyLoss, :hold_next, [c.faults])
    assert :ok = release(c)
    eventually(fn -> cluster_call(c.cluster, c.control, JournalReplyLoss, :waiting, [c.faults]) end)
    {:ok, stored} = cluster_call(c.cluster, c.control, Journal, :open, [c.adapter, {c.namespace, "default"}])
    partial = Enum.find(stored.record["operations"], &(&1["id"] == drain.id))
    assert Enum.count(partial["steps"], &(&1["phase"] == "completed")) == 1
    assert length(stored.record["claims"]) == 3
    [{first, 1}, {second, 2}] = workers
    refute cluster_call(c.cluster, source, Process, :alive?, [first.agent])
    assert cluster_call(c.cluster, source, Process, :alive?, [second.agent])

    c = crash(c)
    assert :ok = cluster_call(c.cluster, c.control, JournalReplyLoss, :release, [c.faults])
    terminate(c, barrier)
    assert %{status: :reconciliation_required} = api(c, :status)
    assert {:ok, %{steps: steps}} = api(c, :operation, [drain.id])

    assert Map.new(steps, fn {id, step} -> {id, Atom.to_string(step.phase)} end) ==
             Map.new(partial["steps"], &{&1["topology"], &1["phase"]})

    recover(c)
    assert {:ok, %{phase: :completed, id: same}} = api(c, :drain, [source, [request_id: token]])
    assert same == drain.id
    assert length(api(c, :claims)) == 2
    assert Enum.all?(api(c, :claims), &(&1.host == target and &1.state == :active))

    for {deployed, committed} <- workers do
      assert node(count(c, deployed.ref, committed)) == target
      refute cluster_call(c.cluster, source, Process, :alive?, [deployed.agent])
    end

    cleanup(c)
  end
end
