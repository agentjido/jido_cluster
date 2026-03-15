defmodule JidoCluster do
  # covers: jido_cluster.bootstrap.namespaces_expose_connected_nodes
  @moduledoc """
  Distributed lifecycle management for Jido agents.

  This package layers distributed ownership and migration behavior around
  `Jido.Agent.InstanceManager` so keyed agents can be managed across multiple
  BEAM nodes.
  """

  @doc "Returns connected nodes including the current node."
  @spec connected_nodes() :: [node()]
  def connected_nodes, do: JidoCluster.Topology.connected_nodes()
end
