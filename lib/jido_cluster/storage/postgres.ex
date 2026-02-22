defmodule JidoCluster.Storage.Postgres do
  @moduledoc """
  Raw-SQL `Jido.Storage` adapter for PostgreSQL through an Ecto repo.

  Required options:

  - `:repo` - Ecto repo module exposing `query/2`, `query/3`, `transaction/1`, and `rollback/1`

  Optional options:

  - `:checkpoints_table` (default: `"jido_cluster_checkpoints"`)
  - `:thread_meta_table` (default: `"jido_cluster_thread_meta"`)
  - `:thread_entries_table` (default: `"jido_cluster_thread_entries"`)

  The adapter uses optimistic concurrency via `expected_rev` by locking the
  thread meta row with `FOR UPDATE` inside a transaction.
  """

  @behaviour Jido.Storage

  alias Jido.Thread
  alias Jido.Thread.Entry
  alias Jido.Thread.EntryNormalizer

  @default_checkpoints_table "jido_cluster_checkpoints"
  @default_thread_meta_table "jido_cluster_thread_meta"
  @default_thread_entries_table "jido_cluster_thread_entries"

  @impl true
  @spec get_checkpoint(term(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  def get_checkpoint(key, opts) do
    with {:ok, repo} <- fetch_repo(opts),
         {:ok, rows} <-
           query_rows(
             repo,
             "SELECT data FROM #{checkpoints_table(opts)} WHERE key = $1 LIMIT 1",
             [serialize_key(key)]
           ) do
      case rows do
        [[data]] -> {:ok, decode_term(data)}
        [] -> :not_found
      end
    end
  end

  @impl true
  @spec put_checkpoint(term(), term(), keyword()) :: :ok | {:error, term()}
  def put_checkpoint(key, data, opts) do
    with {:ok, repo} <- fetch_repo(opts),
         {:ok, _rows} <-
           query_rows(
             repo,
             """
             INSERT INTO #{checkpoints_table(opts)} (key, data, inserted_at, updated_at)
             VALUES ($1, $2, NOW(), NOW())
             ON CONFLICT (key)
             DO UPDATE SET data = EXCLUDED.data, updated_at = NOW()
             """,
             [serialize_key(key), encode_term(data)]
           ) do
      :ok
    end
  end

  @impl true
  @spec delete_checkpoint(term(), keyword()) :: :ok | {:error, term()}
  def delete_checkpoint(key, opts) do
    with {:ok, repo} <- fetch_repo(opts),
         {:ok, _rows} <-
           query_rows(repo, "DELETE FROM #{checkpoints_table(opts)} WHERE key = $1", [serialize_key(key)]) do
      :ok
    end
  end

  @impl true
  @spec load_thread(String.t(), keyword()) :: {:ok, Thread.t()} | :not_found | {:error, term()}
  def load_thread(thread_id, opts) do
    with {:ok, repo} <- fetch_repo(opts),
         {:ok, meta_rows} <-
           query_rows(
             repo,
             """
             SELECT rev, created_at, updated_at, metadata
             FROM #{thread_meta_table(opts)}
             WHERE thread_id = $1
             LIMIT 1
             """,
             [thread_id]
           ) do
      case meta_rows do
        [] ->
          :not_found

        [[rev, created_at, updated_at, metadata_bin]] ->
          with {:ok, entry_rows} <-
                 query_rows(
                   repo,
                   """
                   SELECT seq, kind, at, payload, refs
                   FROM #{thread_entries_table(opts)}
                   WHERE thread_id = $1
                   ORDER BY seq ASC
                   """,
                   [thread_id]
                 ) do
            case entry_rows do
              [] ->
                :not_found

              rows ->
                entries = Enum.map(rows, &row_to_entry/1)

                {:ok,
                 %Thread{
                   id: thread_id,
                   rev: rev,
                   entries: entries,
                   created_at: created_at,
                   updated_at: updated_at,
                   metadata: decode_term(metadata_bin) || %{},
                   stats: %{entry_count: length(entries)}
                 }}
            end
          end
      end
    end
  end

  @impl true
  @spec append_thread(String.t(), [Entry.t() | map()], keyword()) :: {:ok, Thread.t()} | {:error, term()}
  def append_thread(thread_id, entries, opts) do
    expected_rev = Keyword.get(opts, :expected_rev)

    with {:ok, repo} <- fetch_repo(opts),
         {:ok, {:ok, thread}} <-
           transact(repo, fn ->
             do_append_thread(repo, thread_id, List.wrap(entries), expected_rev, opts)
           end) do
      {:ok, thread}
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :conflict} -> {:error, :conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec delete_thread(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_thread(thread_id, opts) do
    with {:ok, repo} <- fetch_repo(opts),
         {:ok, _result} <-
           transact(repo, fn ->
             {:ok, _} =
               query_rows(
                 repo,
                 "DELETE FROM #{thread_entries_table(opts)} WHERE thread_id = $1",
                 [thread_id]
               )

             {:ok, _} =
               query_rows(
                 repo,
                 "DELETE FROM #{thread_meta_table(opts)} WHERE thread_id = $1",
                 [thread_id]
               )

             :ok
           end) do
      :ok
    end
  end

  defp do_append_thread(repo, thread_id, entries, expected_rev, opts) do
    now = System.system_time(:millisecond)

    {current_rev, created_at, metadata} =
      case query_rows(
             repo,
             """
             SELECT rev, created_at, metadata
             FROM #{thread_meta_table(opts)}
             WHERE thread_id = $1
             FOR UPDATE
             """,
             [thread_id]
           ) do
        {:ok, [[rev, created, metadata_bin]]} ->
          {rev, created, decode_term(metadata_bin) || %{}}

        {:ok, []} ->
          {0, now, Keyword.get(opts, :metadata, %{})}

        {:error, reason} ->
          rollback(repo, reason)
      end

    if expected_rev != nil and expected_rev != current_rev do
      rollback(repo, :conflict)
    end

    prepared_entries = EntryNormalizer.normalize_many(entries, current_rev, now)

    Enum.each(prepared_entries, fn %Entry{} = entry ->
      case query_rows(
             repo,
             """
             INSERT INTO #{thread_entries_table(opts)}
               (thread_id, seq, kind, at, payload, refs, inserted_at, updated_at)
             VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())
             """,
             [
               thread_id,
               entry.seq,
               Atom.to_string(entry.kind),
               entry.at,
               encode_term(entry.payload || %{}),
               encode_term(entry.refs || %{})
             ]
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> rollback(repo, reason)
      end
    end)

    new_rev = current_rev + length(prepared_entries)

    case query_rows(
           repo,
           """
           INSERT INTO #{thread_meta_table(opts)}
             (thread_id, rev, metadata, created_at, updated_at, inserted_at, record_updated_at)
           VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
           ON CONFLICT (thread_id)
           DO UPDATE SET rev = EXCLUDED.rev,
                         metadata = EXCLUDED.metadata,
                         updated_at = EXCLUDED.updated_at,
                         record_updated_at = NOW()
           """,
           [thread_id, new_rev, encode_term(metadata), created_at, now]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> rollback(repo, reason)
    end

    case query_rows(
           repo,
           """
           SELECT seq, kind, at, payload, refs
           FROM #{thread_entries_table(opts)}
           WHERE thread_id = $1
           ORDER BY seq ASC
           """,
           [thread_id]
         ) do
      {:ok, rows} ->
        entries = Enum.map(rows, &row_to_entry/1)

        {:ok,
         %Thread{
           id: thread_id,
           rev: new_rev,
           entries: entries,
           created_at: created_at,
           updated_at: now,
           metadata: metadata,
           stats: %{entry_count: length(entries)}
         }}

      {:error, reason} ->
        rollback(repo, reason)
    end
  end

  defp row_to_entry([seq, kind, at, payload, refs]) do
    %Entry{
      id: "entry_#{seq}",
      seq: seq,
      at: at,
      kind: kind_to_atom(kind),
      payload: decode_term(payload) || %{},
      refs: decode_term(refs) || %{}
    }
  end

  defp kind_to_atom(kind) when is_atom(kind), do: kind

  defp kind_to_atom(kind) when is_binary(kind) do
    String.to_existing_atom(kind)
  rescue
    ArgumentError -> :unknown
  end

  defp kind_to_atom(_), do: :unknown

  defp checkpoints_table(opts), do: table_identifier(opts, :checkpoints_table, @default_checkpoints_table)
  defp thread_meta_table(opts), do: table_identifier(opts, :thread_meta_table, @default_thread_meta_table)

  defp thread_entries_table(opts),
    do: table_identifier(opts, :thread_entries_table, @default_thread_entries_table)

  defp table_identifier(opts, key, default) do
    table = Keyword.get(opts, key, default)

    if valid_identifier?(table) do
      table
    else
      raise ArgumentError, "Invalid table identifier for #{inspect(key)}: #{inspect(table)}"
    end
  end

  defp valid_identifier?(name) when is_binary(name) do
    Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name)
  end

  defp valid_identifier?(_), do: false

  defp serialize_key(key) do
    key
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp fetch_repo(opts) do
    case Keyword.get(opts, :repo) do
      repo when is_atom(repo) ->
        if Code.ensure_loaded?(repo) do
          {:ok, repo}
        else
          {:error, {:repo_not_loaded, repo}}
        end

      nil ->
        {:error, :missing_repo}

      other ->
        {:error, {:invalid_repo, other}}
    end
  end

  defp query_rows(repo, sql, params) do
    case repo.query(sql, params) do
      {:ok, result} -> {:ok, Map.get(result, :rows, [])}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp transact(repo, fun) do
    case repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:ok, other}
    end
  rescue
    error -> {:error, error}
  end

  defp rollback(repo, reason) do
    if function_exported?(repo, :rollback, 1) do
      repo.rollback(reason)
    else
      throw({:rollback_unavailable, reason})
    end
  end

  defp encode_term(term), do: :erlang.term_to_binary(term)
  defp decode_term(binary), do: :erlang.binary_to_term(binary, [:safe])
end
