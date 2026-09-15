defmodule JidoClusterTest do
  use ExUnit.Case, async: true

  test "exposes connected_nodes/0 on legacy namespace" do
    assert is_list(JidoCluster.connected_nodes())
  end

  test "exposes connected_nodes/0 on preferred namespace" do
    assert is_list(Jido.Cluster.connected_nodes())
  end
end
