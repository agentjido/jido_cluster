defmodule Jido.Cluster.Storage.Mnesia do
  @moduledoc """
  Mnesia-backed `Jido.Storage` adapter.

  Preferred public namespace. Delegates to `JidoCluster.Storage.Mnesia`.
  """

  @behaviour Jido.Storage

  @impl true
  defdelegate get_checkpoint(key, opts), to: JidoCluster.Storage.Mnesia

  @impl true
  defdelegate put_checkpoint(key, data, opts), to: JidoCluster.Storage.Mnesia

  @impl true
  defdelegate delete_checkpoint(key, opts), to: JidoCluster.Storage.Mnesia

  @impl true
  defdelegate load_thread(thread_id, opts), to: JidoCluster.Storage.Mnesia

  @impl true
  defdelegate append_thread(thread_id, entries, opts), to: JidoCluster.Storage.Mnesia

  @impl true
  defdelegate delete_thread(thread_id, opts), to: JidoCluster.Storage.Mnesia
end
