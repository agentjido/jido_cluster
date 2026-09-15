defmodule Jido.Cluster.StorageCapabilities do
  @moduledoc """
  Backend capability helpers for cluster migration behavior.

  Preferred public namespace. Delegates to `JidoCluster.StorageCapabilities`.
  """

  @type storage_config :: nil | module() | {module(), keyword()}

  @doc "Returns true when the backend is durable/shared and safe for migrations."
  @spec shared_backend?(storage_config()) :: boolean()
  defdelegate shared_backend?(storage), to: JidoCluster.StorageCapabilities

  @doc "Returns true when an adapter + options pair supports cross-node migration semantics."
  @spec shared_backend?(module(), keyword()) :: boolean()
  defdelegate shared_backend?(adapter, opts), to: JidoCluster.StorageCapabilities
end
