defmodule JidoCluster.StructsTest do
  use ExUnit.Case, async: true

  alias Jido.Cluster.{
    Config,
    Ownership,
    Placement,
    Replication,
    RuntimeSnapshot,
    RuntimeSummary,
    Topology.View
  }

  test "config normalizes nested replication into a typed struct" do
    assert {:ok, %Config{} = config} =
             Config.new(
               name: :agents,
               agent: JidoCluster.Test.CounterAgent,
               handoff_mode: :live_transfer,
               partition_policy: :soft_owner,
               replication: %{replicas: 1, mode: :sync, promotion_timeout_ms: 750}
             )

    assert %Replication{} = config.replication
    assert config.replication.mode == :sync
    assert config.handoff_mode == :live_transfer
    assert config.partition_policy == :soft_owner
  end

  test "live transfer rejects async replication because acknowledgements are sync-only" do
    assert {:error, _reason} =
             Config.new(
               name: :agents,
               agent: JidoCluster.Test.CounterAgent,
               handoff_mode: :live_transfer,
               replication: %{replicas: 1, mode: :async, promotion_timeout_ms: 750}
             )
  end

  test "placement captures primary and standby ordering" do
    placement =
      Placement.new!(
        manager: :agents,
        key: "conversation-1",
        primary: :node_a,
        standby: :node_b,
        nodes: [:node_a, :node_b]
      )

    assert placement.primary == :node_a
    assert placement.standby == :node_b
    assert placement.nodes == [:node_a, :node_b]
  end

  test "runtime summary and ownership share the same role semantics" do
    ownership =
      Ownership.new!(
        manager: :agents,
        key: "conversation-1",
        epoch: 2,
        seq: 5,
        primary: :node_a,
        standby: :node_b,
        role: :primary,
        status: :owned
      )

    summary =
      RuntimeSummary.new!(
        manager: ownership.manager,
        key: ownership.key,
        node: :node_a,
        role: ownership.role,
        epoch: ownership.epoch,
        seq: ownership.seq,
        primary: ownership.primary,
        standby: ownership.standby,
        status: ownership.status,
        agent_pid: self()
      )

    assert summary.role == :primary
    assert summary.status == :owned
    assert summary.seq == 5
  end

  test "runtime snapshot wraps an agent snapshot for handoff" do
    snapshot =
      RuntimeSnapshot.new!(
        manager: :agents,
        key: "conversation-1",
        epoch: 3,
        seq: 8,
        cluster_role: :standby,
        primary: :node_a,
        standby: :node_b,
        agent_snapshot: %{agent: %{id: "agent-1"}}
      )

    assert snapshot.cluster_role == :standby
    assert snapshot.primary == :node_a
    assert snapshot.agent_snapshot.agent.id == "agent-1"
  end

  test "topology view records leader and quorum" do
    view = View.new!(nodes: [:node_a, :node_b], leader: :node_a, quorum_met?: true, observed_at: 123)

    assert view.leader == :node_a
    assert view.quorum_met?
  end
end
