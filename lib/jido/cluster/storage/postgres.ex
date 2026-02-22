defmodule Jido.Cluster.Storage.Postgres do
  @moduledoc """
  Raw-SQL `Jido.Storage` adapter for PostgreSQL through an Ecto repo.

  Preferred public namespace. Delegates to `JidoCluster.Storage.Postgres`.
  """

  @behaviour Jido.Storage

  @impl true
  defdelegate get_checkpoint(key, opts), to: JidoCluster.Storage.Postgres

  @impl true
  defdelegate put_checkpoint(key, data, opts), to: JidoCluster.Storage.Postgres

  @impl true
  defdelegate delete_checkpoint(key, opts), to: JidoCluster.Storage.Postgres

  @impl true
  defdelegate load_thread(thread_id, opts), to: JidoCluster.Storage.Postgres

  @impl true
  defdelegate append_thread(thread_id, entries, opts), to: JidoCluster.Storage.Postgres

  @impl true
  defdelegate delete_thread(thread_id, opts), to: JidoCluster.Storage.Postgres
end
