defmodule JidoCluster.Distributed.PeerSmokeTest do
  use JidoCluster.Test.ClusterCase

  test "local peers connect and load cluster modules", %{cluster: cluster} do
    for worker <- cluster.nodes do
      assert cluster_call(cluster, worker, Jido.Cluster.Topology, :connected_nodes, []) == cluster.nodes
    end
  end
end
