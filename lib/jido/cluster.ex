defmodule Jido.Cluster do
  # covers: jido_cluster.package.public_namespace
  # covers: jido_cluster.bootstrap.namespaces_expose_connected_nodes
  @moduledoc """
  Distributed lifecycle management for Jido agents.

  Preferred public namespace for `jido_cluster`.
  """

  @doc "Returns connected nodes including the current node."
  @spec connected_nodes() :: [node()]
  defdelegate connected_nodes(), to: JidoCluster
end
