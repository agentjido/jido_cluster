defmodule JidoCluster.TopologyTest do
  use ExUnit.Case, async: true

  alias JidoCluster.Topology

  test "connected_nodes includes self" do
    assert node() in Topology.connected_nodes()
  end

  test "quorum_met?/2 returns true when node count meets the threshold" do
    nodes = [:"a@127.0.0.1", :"b@127.0.0.1", :"c@127.0.0.1"]

    assert Topology.quorum_met?(1, nodes)
    assert Topology.quorum_met?(2, nodes)
    assert Topology.quorum_met?(3, nodes)
    refute Topology.quorum_met?(4, nodes)
  end

  test "leader_node/1 returns the smallest visible node name" do
    nodes = [:"c@127.0.0.1", :"a@127.0.0.1", :"b@127.0.0.1"]

    assert Topology.leader_node(Enum.sort(nodes)) == :"a@127.0.0.1"
  end

  test "owner_node is deterministic for a fixed node list" do
    nodes = [:"a@127.0.0.1", :"b@127.0.0.1", :"c@127.0.0.1"]

    owner1 = Topology.owner_node(:sessions, "user-123", nodes)
    owner2 = Topology.owner_node(:sessions, "user-123", nodes)

    assert owner1 == owner2
  end

  test "owner_node handles empty nodes by falling back to connected nodes" do
    assert is_atom(Topology.owner_node(:sessions, "user-123", []))
  end

  test "replica_nodes returns stable primary and standby ordering" do
    nodes = [:"a@127.0.0.1", :"b@127.0.0.1", :"c@127.0.0.1"]

    replicas1 = Topology.replica_nodes(:sessions, "user-123", nodes, 2)
    replicas2 = Topology.replica_nodes(:sessions, "user-123", nodes, 2)

    assert replicas1 == replicas2
    assert length(replicas1) == 2
    assert hd(replicas1) == Topology.owner_node(:sessions, "user-123", nodes)
  end
end
