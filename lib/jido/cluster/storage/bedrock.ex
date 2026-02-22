defmodule Jido.Cluster.Storage.Bedrock do
  @moduledoc """
  Bedrock-backed `Jido.Storage` adapter.

  Preferred public namespace. Delegates to `JidoCluster.Storage.Bedrock`.
  """

  @behaviour Jido.Storage

  @impl true
  defdelegate get_checkpoint(key, opts), to: JidoCluster.Storage.Bedrock

  @impl true
  defdelegate put_checkpoint(key, data, opts), to: JidoCluster.Storage.Bedrock

  @impl true
  defdelegate delete_checkpoint(key, opts), to: JidoCluster.Storage.Bedrock

  @impl true
  defdelegate load_thread(thread_id, opts), to: JidoCluster.Storage.Bedrock

  @impl true
  defdelegate append_thread(thread_id, entries, opts), to: JidoCluster.Storage.Bedrock

  @impl true
  defdelegate delete_thread(thread_id, opts), to: JidoCluster.Storage.Bedrock
end
