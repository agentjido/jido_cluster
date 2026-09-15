defmodule Jido.Cluster.Topology do
  # covers: jido_cluster.package.public_namespace
  # covers: jido_cluster.topology.deterministic_primary_standby
  @moduledoc """
  Cluster topology and deterministic ownership helpers.

  Preferred public namespace. Delegates to `JidoCluster.Topology`.
  """

  @doc "Returns connected nodes including `Node.self/0`, sorted deterministically."
  @spec connected_nodes() :: [node()]
  defdelegate connected_nodes(), to: JidoCluster.Topology

  @doc "Returns a topology snapshot for the given node set."
  @spec view([node()], pos_integer()) :: Jido.Cluster.Topology.View.t()
  defdelegate view(nodes \\ JidoCluster.Topology.connected_nodes(), min_quorum_nodes \\ 1),
    to: JidoCluster.Topology

  @doc "Returns the owner node for the given manager and key."
  @spec owner_node(term(), term(), [node()]) :: node()
  defdelegate owner_node(manager, key, nodes), to: JidoCluster.Topology

  @doc "Returns the deterministic placement for the given manager and key."
  @spec placement(term(), term(), [node()], pos_integer()) :: Jido.Cluster.Placement.t()
  defdelegate placement(manager, key, nodes, count \\ 2), to: JidoCluster.Topology

  @doc "Returns the ordered replica nodes for the given manager and key."
  @spec replica_nodes(term(), term(), [node()], pos_integer()) :: [node()]
  defdelegate replica_nodes(manager, key, nodes, count \\ 2), to: JidoCluster.Topology
end
