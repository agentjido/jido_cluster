defmodule Jido.Cluster.Storage.ETS do
  @moduledoc """
  ETS adapter shim for `Jido.Storage`.

  Preferred public namespace. Delegates to `JidoCluster.Storage.ETS`.
  """

  @behaviour Jido.Storage

  @impl true
  defdelegate get_checkpoint(key, opts), to: JidoCluster.Storage.ETS

  @impl true
  defdelegate put_checkpoint(key, data, opts), to: JidoCluster.Storage.ETS

  @impl true
  defdelegate delete_checkpoint(key, opts), to: JidoCluster.Storage.ETS

  @impl true
  defdelegate load_thread(thread_id, opts), to: JidoCluster.Storage.ETS

  @impl true
  defdelegate append_thread(thread_id, entries, opts), to: JidoCluster.Storage.ETS

  @impl true
  defdelegate delete_thread(thread_id, opts), to: JidoCluster.Storage.ETS
end
