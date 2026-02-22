defmodule Jido.Cluster.ClusterFormation do
  @moduledoc """
  Optional cluster formation supervisor.

  Preferred public namespace. Delegates to `JidoCluster.ClusterFormation`.
  """

  @doc "Child specification for optional cluster formation services."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(opts), to: JidoCluster.ClusterFormation

  @doc "Starts the cluster-formation supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(opts), to: JidoCluster.ClusterFormation
end
