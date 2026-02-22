defmodule JidoCluster.Storage.ETS do
  @moduledoc """
  ETS adapter shim for `Jido.Storage`.

  Delegates to `Jido.Storage.ETS`. This backend is local/ephemeral and therefore
  not considered shared for automatic migrations.
  """

  @behaviour Jido.Storage

  @impl true
  defdelegate get_checkpoint(key, opts), to: Jido.Storage.ETS

  @impl true
  defdelegate put_checkpoint(key, data, opts), to: Jido.Storage.ETS

  @impl true
  defdelegate delete_checkpoint(key, opts), to: Jido.Storage.ETS

  @impl true
  defdelegate load_thread(thread_id, opts), to: Jido.Storage.ETS

  @impl true
  defdelegate append_thread(thread_id, entries, opts), to: Jido.Storage.ETS

  @impl true
  defdelegate delete_thread(thread_id, opts), to: Jido.Storage.ETS
end
