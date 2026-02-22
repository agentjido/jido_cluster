defmodule JidoCluster.Storage.Mnesia do
  @moduledoc """
  Mnesia-backed `Jido.Storage` adapter.

  Tables:

  - checkpoints (`set`): `{table, key, data}`
  - thread meta (`set`): `{table, thread_id, rev, created_at, updated_at, metadata}`
  - thread entries (`ordered_set`): `{table, {thread_id, seq}, entry}`

  This adapter supports `expected_rev` conflict checks in `append_thread/3`.
  """

  @behaviour Jido.Storage

  alias Jido.Thread
  alias Jido.Thread.Entry
  alias Jido.Thread.EntryNormalizer

  @default_table :jido_cluster_storage

  @impl true
  @spec get_checkpoint(term(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  def get_checkpoint(key, opts) do
    with :ok <- ensure_tables(opts) do
      case :mnesia.transaction(fn ->
             case :mnesia.read(checkpoint_table(opts), key, :read) do
               [{_table, ^key, data}] -> {:ok, data}
               [] -> :not_found
             end
           end) do
        {:atomic, result} -> result
        {:aborted, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  @spec put_checkpoint(term(), term(), keyword()) :: :ok | {:error, term()}
  def put_checkpoint(key, data, opts) do
    with :ok <- ensure_tables(opts) do
      case :mnesia.transaction(fn ->
             :mnesia.write({checkpoint_table(opts), key, data})
             :ok
           end) do
        {:atomic, :ok} -> :ok
        {:aborted, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  @spec delete_checkpoint(term(), keyword()) :: :ok | {:error, term()}
  def delete_checkpoint(key, opts) do
    with :ok <- ensure_tables(opts) do
      case :mnesia.transaction(fn ->
             :mnesia.delete({checkpoint_table(opts), key})
             :ok
           end) do
        {:atomic, :ok} -> :ok
        {:aborted, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  @spec load_thread(String.t(), keyword()) :: {:ok, Thread.t()} | :not_found | {:error, term()}
  def load_thread(thread_id, opts) do
    with :ok <- ensure_tables(opts) do
      case :mnesia.transaction(fn -> do_load_thread_tx(thread_id, opts) end) do
        {:atomic, result} -> result
        {:aborted, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  @spec append_thread(String.t(), [Entry.t() | map()], keyword()) :: {:ok, Thread.t()} | {:error, term()}
  def append_thread(thread_id, entries, opts) do
    with :ok <- ensure_tables(opts) do
      case :mnesia.transaction(fn -> do_append_thread_tx(thread_id, List.wrap(entries), opts) end) do
        {:atomic, {:ok, thread}} -> {:ok, thread}
        {:aborted, :conflict} -> {:error, :conflict}
        {:aborted, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  @spec delete_thread(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_thread(thread_id, opts) do
    with :ok <- ensure_tables(opts) do
      case :mnesia.transaction(fn ->
             :mnesia.delete({meta_table(opts), thread_id})
             delete_entries_tx(entries_table(opts), thread_id)
             :ok
           end) do
        {:atomic, :ok} -> :ok
        {:aborted, reason} -> {:error, reason}
      end
    end
  end

  defp do_load_thread_tx(thread_id, opts) do
    entries = load_entries_tx(entries_table(opts), thread_id)

    case entries do
      [] ->
        :not_found

      entries ->
        {rev, created_at, updated_at, metadata} = load_meta_tx(meta_table(opts), thread_id, entries)
        {:ok, reconstruct_thread(thread_id, rev, entries, created_at, updated_at, metadata)}
    end
  end

  defp do_append_thread_tx(thread_id, entries, opts) do
    now = System.system_time(:millisecond)
    expected_rev = Keyword.get(opts, :expected_rev)
    metadata_from_opts = Keyword.get(opts, :metadata, %{})

    {current_rev, created_at, metadata} =
      case :mnesia.read(meta_table(opts), thread_id, :write) do
        [{_table, ^thread_id, rev, created, _updated, meta}] -> {rev, created, meta || %{}}
        [] -> {0, now, metadata_from_opts}
      end

    if conflict?(expected_rev, current_rev) do
      :mnesia.abort(:conflict)
    end

    prepared_entries = EntryNormalizer.normalize_many(entries, current_rev, now)

    Enum.each(prepared_entries, fn %Entry{} = entry ->
      :mnesia.write({entries_table(opts), {thread_id, entry.seq}, entry})
    end)

    new_rev = current_rev + length(prepared_entries)

    :mnesia.write({meta_table(opts), thread_id, new_rev, created_at, now, metadata})

    all_entries = load_entries_tx(entries_table(opts), thread_id)

    {:ok, reconstruct_thread(thread_id, new_rev, all_entries, created_at, now, metadata)}
  end

  defp conflict?(nil, _current_rev), do: false
  defp conflict?(expected_rev, current_rev), do: expected_rev != current_rev

  defp load_meta_tx(meta_table, thread_id, entries) do
    case :mnesia.read(meta_table, thread_id, :read) do
      [{_table, ^thread_id, rev, created_at, updated_at, metadata}] ->
        {rev, created_at, updated_at, metadata || %{}}

      [] ->
        created_at = entries |> List.first() |> Map.get(:at)
        updated_at = entries |> List.last() |> Map.get(:at)
        {length(entries), created_at, updated_at, %{}}
    end
  end

  defp load_entries_tx(entries_table, thread_id) do
    entries_table
    |> :mnesia.select([
      {{entries_table, {thread_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.sort_by(fn {seq, _entry} -> seq end)
    |> Enum.map(fn {_seq, entry} -> entry end)
  end

  defp delete_entries_tx(entries_table, thread_id) do
    keys =
      :mnesia.select(entries_table, [
        {{entries_table, {thread_id, :"$1"}, :_}, [], [:"$1"]}
      ])

    Enum.each(keys, fn seq ->
      :mnesia.delete({entries_table, {thread_id, seq}})
    end)

    :ok
  end

  defp reconstruct_thread(thread_id, rev, entries, created_at, updated_at, metadata) do
    %Thread{
      id: thread_id,
      rev: rev,
      entries: entries,
      created_at: created_at,
      updated_at: updated_at,
      metadata: metadata || %{},
      stats: %{entry_count: length(entries)}
    }
  end

  defp checkpoint_table(opts), do: table_name(opts, :checkpoints)
  defp meta_table(opts), do: table_name(opts, :thread_meta)
  defp entries_table(opts), do: table_name(opts, :thread_entries)

  defp table_name(opts, suffix) do
    base = Keyword.get(opts, :table, @default_table)
    :"#{base}_#{suffix}"
  end

  defp ensure_tables(opts) do
    with :ok <- ensure_mnesia_started(),
         :ok <- ensure_table(checkpoint_table(opts), [:key, :data], :set, opts),
         :ok <- ensure_table(meta_table(opts), [:thread_id, :rev, :created_at, :updated_at, :metadata], :set, opts),
         :ok <- ensure_table(entries_table(opts), [:id, :entry], :ordered_set, opts) do
      :ok
    end
  end

  defp ensure_mnesia_started do
    case :mnesia.system_info(:is_running) do
      :yes ->
        :ok

      :starting ->
        :ok

      :no ->
        case :mnesia.start() do
          :ok -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ensure_table(name, attributes, type, opts) do
    case :mnesia.create_table(name, table_opts(attributes, type, opts)) do
      {:atomic, :ok} ->
        :mnesia.wait_for_tables([name], 5_000)

      {:aborted, {:already_exists, ^name}} ->
        :ok

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  defp table_opts(attributes, type, opts) do
    copy_opts =
      cond do
        Keyword.has_key?(opts, :disc_copies) -> [disc_copies: Keyword.fetch!(opts, :disc_copies)]
        Keyword.has_key?(opts, :ram_copies) -> [ram_copies: Keyword.fetch!(opts, :ram_copies)]
        true -> [ram_copies: [Node.self()]]
      end

    [attributes: attributes, type: type] ++ copy_opts
  end
end
