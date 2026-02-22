defmodule JidoCluster.TopologyTest do
  use ExUnit.Case, async: true

  alias JidoCluster.Topology

  test "connected_nodes includes self" do
    assert node() in Topology.connected_nodes()
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
end
