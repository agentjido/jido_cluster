defmodule JidoCluster.Storage.Bedrock do
  @moduledoc """
  Bedrock-backed `Jido.Storage` adapter.

  Required options:

  - `:repo` - module implementing `Bedrock.Repo` behavior

  Optional options:

  - `:prefix` - key prefix (default: `"jido_cluster/"`)
  """

  @behaviour Jido.Storage

  alias Jido.Thread
  alias Jido.Thread.Entry
  alias Jido.Thread.EntryNormalizer

  @default_prefix "jido_cluster/"

  @impl true
  @spec get_checkpoint(term(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  def get_checkpoint(key, opts) do
    with {:ok, repo} <- fetch_repo(opts),
         {:ok, result} <-
           transact(repo, fn ->
             case repo.get(checkpoint_key(prefix(opts), key)) do
               nil -> :not_found
               binary -> {:ok, decode_term(binary)}
             end
           end) do
      result
    end
  end

  @impl true
  @spec put_checkpoint(term(), term(), keyword()) :: :ok | {:error, term()}
  def put_checkpoint(key, data, opts) do
    with {:ok, repo} <- fetch_repo(opts),
         {:ok, :ok} <-
           transact(repo, fn ->
             :ok = repo.put(checkpoint_key(prefix(opts), key), encode_term(data))
             :ok
           end) do
      :ok
    end
  end

  @impl true
  @spec delete_checkpoint(term(), keyword()) :: :ok | {:error, term()}
  def delete_checkpoint(key, opts) do
    with {:ok, repo} <- fetch_repo(opts),
         {:ok, :ok} <-
           transact(repo, fn ->
             :ok = repo.clear(checkpoint_key(prefix(opts), key))
             :ok
           end) do
      :ok
    end
  end

  @impl true
  @spec load_thread(String.t(), keyword()) :: {:ok, Thread.t()} | :not_found | {:error, term()}
  def load_thread(thread_id, opts) do
    with {:ok, repo} <- fetch_repo(opts),
         {:ok, result} <-
           transact(repo, fn ->
             do_load_thread(repo, prefix(opts), thread_id)
           end) do
      result
    end
  end

  @impl true
  @spec append_thread(String.t(), [Entry.t() | map()], keyword()) :: {:ok, Thread.t()} | {:error, term()}
  def append_thread(thread_id, entries, opts) do
    expected_rev = Keyword.get(opts, :expected_rev)

    with {:ok, repo} <- fetch_repo(opts),
         {:ok, result} <-
           transact(repo, fn ->
             do_append_thread(repo, prefix(opts), thread_id, List.wrap(entries), expected_rev, opts)
           end) do
      result
    end
  end

  @impl true
  @spec delete_thread(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_thread(thread_id, opts) do
    with {:ok, repo} <- fetch_repo(opts),
         {:ok, :ok} <-
           transact(repo, fn ->
             pfx = prefix(opts)
             :ok = repo.clear(thread_meta_key(pfx, thread_id))

             {start_key, end_key} = thread_entries_range(pfx, thread_id)
             :ok = repo.clear_range({start_key, end_key})
             :ok
           end) do
      :ok
    end
  end

  defp do_load_thread(repo, pfx, thread_id) do
    case repo.get(thread_meta_key(pfx, thread_id)) do
      nil ->
        :not_found

      encoded_meta ->
        meta = decode_term(encoded_meta)
        entries = load_entries(repo, pfx, thread_id)

        if entries == [] do
          :not_found
        else
          {:ok, reconstruct_thread(thread_id, meta, entries)}
        end
    end
  end

  defp do_append_thread(repo, pfx, thread_id, entries, expected_rev, opts) do
    now = System.system_time(:millisecond)
    meta_key = thread_meta_key(pfx, thread_id)

    {current_rev, created_at, metadata, existing_entries} =
      case repo.get(meta_key) do
        nil ->
          {0, now, Keyword.get(opts, :metadata, %{}), []}

        encoded_meta ->
          meta = decode_term(encoded_meta)
          existing_entries = load_entries(repo, pfx, thread_id)
          {meta.rev || 0, meta.created_at || now, meta.metadata || %{}, existing_entries}
      end

    if expected_rev != nil and expected_rev != current_rev do
      rollback(repo, :conflict)
    end

    prepared_entries = EntryNormalizer.normalize_many(entries, current_rev, now)

    Enum.each(prepared_entries, fn %Entry{} = entry ->
      :ok = repo.put(thread_entry_key(pfx, thread_id, entry.seq), encode_term(entry))
    end)

    new_rev = current_rev + length(prepared_entries)

    :ok =
      repo.put(
        meta_key,
        encode_term(%{
          rev: new_rev,
          created_at: created_at,
          updated_at: now,
          metadata: metadata
        })
      )

    all_entries = existing_entries ++ prepared_entries

    {:ok,
     reconstruct_thread(
       thread_id,
       %{rev: new_rev, created_at: created_at, updated_at: now, metadata: metadata},
       all_entries
     )}
  end

  defp load_entries(repo, pfx, thread_id) do
    {start_key, end_key} = thread_entries_range(pfx, thread_id)

    repo.get_range({start_key, end_key})
    |> Enum.map(fn {_key, value} -> decode_term(value) end)
    |> Enum.sort_by(& &1.seq)
  end

  defp reconstruct_thread(thread_id, meta, entries) do
    %Thread{
      id: thread_id,
      rev: meta.rev,
      entries: entries,
      created_at: meta.created_at,
      updated_at: meta.updated_at,
      metadata: meta.metadata || %{},
      stats: %{entry_count: length(entries)}
    }
  end

  defp prefix(opts), do: Keyword.get(opts, :prefix, @default_prefix)

  defp checkpoint_key(prefix, key), do: prefix <> "checkpoints/" <> encode_key_component(key)

  defp thread_meta_key(prefix, thread_id),
    do: prefix <> "threads/" <> encode_key_component(thread_id) <> "/meta"

  defp thread_entry_key(prefix, thread_id, seq) do
    thread_entries_prefix(prefix, thread_id) <> <<seq::unsigned-big-integer-size(64)>>
  end

  defp thread_entries_range(prefix, thread_id) do
    start_key = thread_entries_prefix(prefix, thread_id)
    end_key = Bedrock.Key.key_after(start_key)
    {start_key, end_key}
  end

  defp thread_entries_prefix(prefix, thread_id),
    do: prefix <> "threads/" <> encode_key_component(thread_id) <> "/entries/"

  defp encode_key_component(term) do
    term
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp encode_term(term), do: :erlang.term_to_binary(term)
  defp decode_term(binary), do: :erlang.binary_to_term(binary, [:safe])

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

  defp transact(repo, fun) when is_function(fun, 0) do
    case repo.transact(fun) do
      {:error, reason} -> {:error, reason}
      result -> {:ok, result}
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
end
