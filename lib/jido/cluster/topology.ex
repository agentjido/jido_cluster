defmodule Jido.Cluster.Topology do
  @moduledoc """
  Cluster topology and deterministic ownership helpers.

  Preferred public namespace. Delegates to `JidoCluster.Topology`.
  """

  @doc "Returns connected nodes including `Node.self/0`, sorted deterministically."
  @spec connected_nodes() :: [node()]
  defdelegate connected_nodes(), to: JidoCluster.Topology

  @doc "Returns the owner node for the given manager and key."
  @spec owner_node(term(), term(), [node()]) :: node()
  defdelegate owner_node(manager, key, nodes), to: JidoCluster.Topology
end
