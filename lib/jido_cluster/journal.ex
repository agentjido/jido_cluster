defmodule Jido.Cluster.Journal do
  @moduledoc """
  Bounded scope records stored through `Jido.Persistence.Store`.

  This module stores portable JSON records. It does not grant scope ownership,
  start Agents, or interpret deployment intent. A connected scope owner must
  record each external step before submitting it. Recovery must confirm a fresh
  revision through CAS before it acts on restored intent. That revision also
  prevents a delayed write with an older comparison value from taking effect.

  Unknown write results and CAS conflicts block the returned handle. `reload/1`
  reads storage without writing or retrying an operation. It can discover a write
  whose reply was lost. Reads retain exact bytes or the adapter's opaque token as
  the next comparison condition. Re-encoding a read value is not a CAS condition.

  The envelope is an internal versioned storage format. It contains namespace,
  scope, revision, write ID, and the record. It is separate from Agent checkpoints.
  """

  alias Jido.Persistence.Store

  @limits %{
    record_bytes: 98_304,
    admission_bytes: 65_536,
    deployments: 16,
    hosts: 32,
    claims: 64,
    unresolved_operations: 16,
    request_bindings: 64,
    depth: 32,
    nodes: 10_000
  }
  @fields ~w(type version namespace scope revision write_id record)
  defstruct [:store, :scope, :key, :record, :write_id, expected: :not_found, revision: 0, status: :ready]
  @type t :: %__MODULE__{}

  @doc "Returns the aggregate bounds used by journal and admission contracts."
  @spec limits() :: map()
  def limits, do: @limits

  @doc "Validates the adapter and reads the stable scope key without writing."
  @spec open(term(), {String.t(), String.t()}) :: {:ok, t()} | {:error, term()}
  def open(adapter, {namespace, scope} = identity) when is_binary(namespace) and is_binary(scope) do
    with true <- namespace != "" and scope != "" and String.valid?(namespace) and String.valid?(scope),
         {:ok, store} <- Store.open(adapter) do
      reload(%__MODULE__{store: store, scope: identity, key: key(identity)})
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_journal_configuration}
    end
  end

  def open(_, _), do: {:error, :invalid_scope}

  @doc "Reads the current value and comparison condition; performs no write or external effect."
  @spec reload(t()) :: {:ok, t()} | {:error, term()}
  def reload(journal) do
    case Store.read(journal.store, journal.key) do
      {:ok, bytes, condition} ->
        read_record(journal, bytes, condition)

      {:error, :not_found} when journal.revision == 0 ->
        {:ok, %{journal | status: :ready}}

      {:error, :not_found} ->
        {:error, :journal_disappeared}

      {:error, reason} ->
        {:error, {:journal_read_failed, reason}}
    end
  end

  @doc "Validates and conditionally writes one new revision, or blocks on an unknown outcome."
  @spec commit(t(), map()) :: {:ok, t()} | {:error, term(), t()}
  def commit(%__MODULE__{status: :ready} = journal, record) do
    {namespace, scope} = journal.scope

    document = %{
      "type" => "jido.cluster.journal",
      "version" => 1,
      "namespace" => namespace,
      "scope" => scope,
      "revision" => journal.revision + 1,
      "write_id" => Jido.generate_id(),
      "record" => record
    }

    with :ok <- record_object(record),
         :ok <- portable(document),
         {:ok, bytes} <- Jason.encode(document),
         :ok <- byte_limit(bytes) do
      result = Store.compare_and_swap(journal.store, journal.key, journal.expected, bytes)

      write_result(result, journal, document, bytes)
    else
      {:error, reason} -> {:error, reason, journal}
    end
  end

  def commit(journal, _record), do: {:error, :reconciliation_required, journal}

  defp write_result(:ok, journal, document, bytes), do: {:ok, load_document(journal, document, bytes)}
  defp write_result({:error, {:rejected, _} = reason}, journal, _, _), do: {:error, reason, journal}
  defp write_result({:error, :conflict}, journal, _, _), do: {:error, :conflict, %{journal | status: :conflict}}

  # Store owns generic outcome classification. Cluster owns the response:
  # neither form of an indeterminate result permits further writes or effects.
  defp write_result({:error, reason}, journal, _, _),
    do: {:error, reason, %{journal | status: :uncertain}}

  defp read_record(journal, bytes, expected) do
    with :ok <- byte_limit(bytes),
         {:ok, document} <- Jason.decode(bytes),
         :ok <- portable(document),
         :ok <- header(document, journal.scope),
         :ok <- history(document, journal) do
      {:ok, load_document(journal, document, expected)}
    else
      {:error, reason} -> {:error, {:invalid_journal_record, reason}}
    end
  end

  defp history(document, journal) do
    cond do
      document["revision"] < journal.revision ->
        {:error, :revision_regressed}

      document["revision"] == journal.revision and
          (document["write_id"] != journal.write_id or document["record"] !== journal.record) ->
        {:error, :revision_changed}

      true ->
        :ok
    end
  end

  defp load_document(journal, document, expected),
    do: %{
      journal
      | record: document["record"],
        revision: document["revision"],
        write_id: document["write_id"],
        expected: expected,
        status: :ready
    }

  defp header(%{"type" => "jido.cluster.journal", "version" => 1} = document, {namespace, scope}) do
    cond do
      Enum.sort(Map.keys(document)) != Enum.sort(@fields) -> {:error, :invalid_fields}
      document["namespace"] != namespace or document["scope"] != scope -> {:error, :scope_mismatch}
      not is_integer(document["revision"]) or document["revision"] < 1 -> {:error, :invalid_revision}
      not is_binary(document["write_id"]) or byte_size(document["write_id"]) != 36 -> {:error, :invalid_write_id}
      true -> record_object(document["record"])
    end
  end

  defp header(_, _), do: {:error, :unsupported_schema}
  defp record_object(record) when is_map(record) and not is_struct(record), do: :ok
  defp record_object(_), do: {:error, {:invalid_record, :expected_object}}
  defp byte_limit(bytes) when byte_size(bytes) <= @limits.record_bytes, do: :ok
  defp byte_limit(bytes), do: {:error, {:record_too_large, byte_size(bytes), @limits.record_bytes}}

  defp key(identity) do
    digest = identity |> Tuple.to_list() |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1))
    "jido:cluster:journal:v1:" <> Base.url_encode64(digest, padding: false)
  end

  defp portable(value) do
    case check(value, 0, 0) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:invalid_record, reason}}
    end
  end

  defp check(_, depth, _) when depth > @limits.depth, do: {:error, :depth_limit}
  defp check(_, _, nodes) when nodes >= @limits.nodes, do: {:error, :node_limit}
  defp check(value, _, nodes) when is_number(value) or is_boolean(value) or is_nil(value), do: {:ok, nodes + 1}

  defp check(value, _, nodes) when is_binary(value),
    do: if(String.valid?(value), do: {:ok, nodes + 1}, else: {:error, :invalid_utf8})

  defp check(value, depth, nodes) when is_map(value) and not is_struct(value) do
    if Enum.all?(Map.keys(value), &is_binary/1),
      do: check_list(Enum.flat_map(value, fn {key, item} -> [key, item] end), depth + 1, nodes + 1),
      else: {:error, :non_string_key}
  end

  defp check(value, depth, nodes) when is_list(value), do: check_list(value, depth + 1, nodes + 1)
  defp check(_, _, _), do: {:error, :non_portable_value}
  defp check_list([], _, nodes), do: {:ok, nodes}

  defp check_list([value | rest], depth, nodes) do
    with {:ok, nodes} <- check(value, depth, nodes), do: check_list(rest, depth, nodes)
  end

  defp check_list(_, _, _), do: {:error, :improper_list}
end
