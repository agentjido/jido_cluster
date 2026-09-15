defmodule Jido.Cluster do
  @moduledoc """
  Connected BEAM cluster foundation for Jido V3 Agents.

  Start the same `Jido.Cluster.InstanceManager` configuration on each worker
  node. Route work through the manager by logical key. Jido owns Agent execution,
  checkpoint encoding, and commit revisions. This package owns placement and
  the lifetime of each keyed activation.

  This foundation does not provide disconnected island leases or live replicas.
  """

  @doc "Returns the visible BEAM nodes, including this node."
  @spec connected_nodes() :: [node()]
  defdelegate connected_nodes(), to: Jido.Cluster.Topology
end
