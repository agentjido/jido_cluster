defmodule JidoCluster.StorageCapabilities do
  @moduledoc """
  Backend capability helpers for cluster migration behavior.
  """

  @type storage_config :: nil | module() | {module(), keyword()}

  @doc "Returns true when the backend is durable/shared and safe for migrations."
  @spec shared_backend?(storage_config()) :: boolean()
  def shared_backend?(nil), do: false

  def shared_backend?({adapter, opts}) when is_atom(adapter) and is_list(opts) do
    shared_backend?(adapter, opts)
  end

  def shared_backend?(adapter) when is_atom(adapter) do
    shared_backend?(adapter, [])
  end

  @doc "Returns true when an adapter + options pair supports cross-node migration semantics."
  @spec shared_backend?(module(), keyword()) :: boolean()
  def shared_backend?(Jido.Storage.ETS, _opts), do: false
  def shared_backend?(JidoCluster.Storage.ETS, _opts), do: false
  def shared_backend?(Jido.Cluster.Storage.ETS, _opts), do: false
  def shared_backend?(JidoCluster.Storage.Mnesia, _opts), do: true
  def shared_backend?(Jido.Cluster.Storage.Mnesia, _opts), do: true
  def shared_backend?(JidoCluster.Storage.Bedrock, _opts), do: true
  def shared_backend?(Jido.Cluster.Storage.Bedrock, _opts), do: true
  def shared_backend?(JidoCluster.Storage.Postgres, _opts), do: true
  def shared_backend?(Jido.Cluster.Storage.Postgres, _opts), do: true

  def shared_backend?(adapter, opts) when is_atom(adapter) and is_list(opts) do
    Keyword.get(opts, :shared, false)
  end
end
