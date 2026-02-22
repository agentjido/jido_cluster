defmodule Jido.Cluster do
  @moduledoc """
  Distributed lifecycle management for Jido agents.

  Preferred public namespace for `jido_cluster`.
  """

  @doc "Returns connected nodes including the current node."
  @spec connected_nodes() :: [node()]
  defdelegate connected_nodes(), to: JidoCluster
end
