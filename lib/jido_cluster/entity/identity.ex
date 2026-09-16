defmodule Jido.Cluster.Entity.Identity do
  @moduledoc """
  Versioned identity for one bounded entity workload.

  The encoded identity includes the workload definition ID, keyspace, and
  domain key. This ID is the core Topology instance ID. Core derives the Agent
  ID and Ref from it. Encoding is stable for portable keys and does not use a
  process location or candidate host.
  """

  @version 1
  # Core Topology keys have a 255-byte limit. This leaves room for the
  # version prefix and URL-safe encoding of the complete identity tuple.
  @max_bytes 180
  @prefix "entity:v1:"

  @doc "Returns the stable Topology ID for a validated domain identity."
  @spec id(String.t(), String.t() | nil, term()) :: {:ok, String.t()} | {:error, atom()}
  def id(definition_id, keyspace, identity) do
    with :ok <- validate_definition(definition_id),
         :ok <- validate_keyspace(keyspace),
         :ok <- validate(identity, keyspace),
         :ok <- portable(identity),
         bytes = :erlang.term_to_binary({definition_id, keyspace, identity}, [:deterministic]),
         true <- byte_size(bytes) <= @max_bytes do
      {:ok, @prefix <> Base.url_encode64(bytes, padding: false)}
    else
      false -> {:error, :identity_too_large}
      error -> error
    end
  end

  @doc "Reads and rechecks a version-one ID without creating atoms."
  @spec parse(term()) :: {:ok, map()} | {:error, :invalid_entity_id}
  def parse(@prefix <> encoded = id) do
    with true <- byte_size(encoded) <= div(@max_bytes * 4 + 2, 3),
         {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(bytes) <= @max_bytes,
         <<131, 104, 3, _::binary>> <- bytes,
         {definition_id, keyspace, identity} <- :erlang.binary_to_term(bytes, [:safe]),
         {:ok, ^id} <- id(definition_id, keyspace, identity) do
      {:ok, %{definition_id: definition_id, keyspace: keyspace, identity: identity}}
    else
      _ -> {:error, :invalid_entity_id}
    end
  rescue
    ArgumentError -> {:error, :invalid_entity_id}
  end

  def parse(_), do: {:error, :invalid_entity_id}

  @doc "Validates a domain key against its optional keyspace."
  @spec validate(term(), String.t() | nil) :: :ok | {:error, :invalid_identity | :keyspace_mismatch}
  def validate(nil, _keyspace), do: {:error, :invalid_identity}
  def validate(_identity, nil), do: :ok

  def validate(identity, keyspace) when is_tuple(identity) and tuple_size(identity) > 0 do
    if elem(identity, 0) == keyspace, do: :ok, else: {:error, :keyspace_mismatch}
  end

  def validate(_identity, _keyspace), do: {:error, :invalid_identity}

  @doc "Returns the supported mapping version and maximum encoded source size."
  @spec limits() :: map()
  def limits, do: %{version: @version, encoded_source_bytes: @max_bytes}

  defp validate_definition(value) when is_binary(value) and byte_size(value) in 1..96 do
    if String.valid?(value), do: :ok, else: {:error, :invalid_definition_id}
  end

  defp validate_definition(_), do: {:error, :invalid_definition_id}

  defp validate_keyspace(nil), do: :ok

  defp validate_keyspace(value) when is_binary(value) and byte_size(value) in 1..96 do
    if String.valid?(value), do: :ok, else: {:error, :invalid_keyspace}
  end

  defp validate_keyspace(_), do: {:error, :invalid_keyspace}

  defp portable(value) do
    if Jido.PortableTerm.valid?(value), do: :ok, else: {:error, :invalid_identity}
  end
end
