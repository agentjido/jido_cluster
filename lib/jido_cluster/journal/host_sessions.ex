defmodule Jido.Cluster.Journal.HostSessions do
  @moduledoc false
  alias Jido.Cluster.{HostSession, Journal}

  @doc "Encodes configured provider identities without runtime options."
  @spec providers(map()) :: [map()]
  def providers(config) do
    config
    |> Map.get(:host_providers, %{})
    |> Enum.sort()
    |> Enum.map(fn {host, provider} ->
      %{"host" => Atom.to_string(host), "provider" => provider.id, "ownership" => Atom.to_string(provider.ownership)}
    end)
  end

  @doc "Validates and encodes one session per configured host."
  @spec encode(map(), map()) :: {:ok, [map()]} | {:error, term()}
  def encode(sessions, config) when is_map(sessions) and map_size(sessions) <= 32 do
    Enum.reduce_while(Enum.sort(sessions), {:ok, []}, fn {host, session}, {:ok, records} ->
      with true <- matches?(host, session, config),
           {:ok, record} <- HostSession.to_record(session) do
        {:cont, {:ok, records ++ [record]}}
      else
        _ -> {:halt, {:error, :invalid_host_sessions}}
      end
    end)
  end

  def encode(_, _), do: {:error, :invalid_host_sessions}

  @doc "Resolves session hosts only from the configured inventory."
  @spec decode(term(), map()) :: {:ok, map()} | {:error, term()}
  def decode(records, config) when is_list(records) do
    if length(records) <= Journal.limits().hosts,
      do: read(records, config),
      else: {:error, :invalid_host_sessions}
  end

  def decode(_, _), do: {:error, :invalid_host_sessions}

  @doc "Checks retained host operation references; completed history may have expired."
  @spec operations(map(), map(), map()) :: :ok | {:error, :invalid_host_operation}
  def operations(sessions, operations, config) do
    sessions_valid =
      Enum.all?(sessions, fn {host, session} ->
        action = if session.desired == :running, do: :acquire_host, else: :release_host

        operation_matches?(operations, session.operation, host, action) and
          operation_matches?(operations, session.step.id, host, :acquire_host)
      end)

    operations_valid =
      Enum.all?(operations, fn {id, op} ->
        if op.action in [:acquire_host, :release_host],
          do: Map.has_key?(Map.get(config, :host_providers, %{}), op.host) and referenced?(sessions, id, op),
          else: true
      end)

    if sessions_valid and operations_valid, do: :ok, else: {:error, :invalid_host_operation}
  end

  defp operation_matches?(operations, id, host, action) do
    case Map.get(operations, id) do
      nil -> true
      %{host: ^host, action: ^action} -> true
      _ -> false
    end
  end

  defp referenced?(_, _, %{phase: phase}) when phase in [:completed, :failed], do: true

  defp referenced?(sessions, id, op) do
    case Map.get(sessions, op.host) do
      nil -> false
      session -> id == session.operation or (op.action == :acquire_host and id == session.step.id)
    end
  end

  defp read(records, config) do
    known = Map.new(config.hosts, &{Atom.to_string(&1.node), &1.node})

    Enum.reduce_while(records, {:ok, %{}}, fn record, {:ok, sessions} ->
      with {:ok, session} <- HostSession.from_record(record),
           {:ok, host} <- Map.fetch(known, session.step.host),
           false <- Map.has_key?(sessions, host),
           true <- matches?(host, session, config) do
        {:cont, {:ok, Map.put(sessions, host, session)}}
      else
        _ -> {:halt, {:error, :invalid_host_sessions}}
      end
    end)
  end

  defp matches?(host, %HostSession{} = session, config) do
    case Map.get(Map.get(config, :host_providers, %{}), host) do
      %{id: id, ownership: ownership} ->
        HostSession.validate(session) == :ok and session.ownership == ownership and session.step.provider == id and
          session.step.host == Atom.to_string(host) and session.step.namespace == config.namespace and
          session.step.scope == config.scope

      _ ->
        false
    end
  end

  defp matches?(_, _, _), do: false
end
