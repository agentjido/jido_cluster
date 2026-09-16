defmodule Jido.Cluster.Instance.HostControl do
  @moduledoc false
  alias Jido.Cluster.HostProvider.{Resource, Step}
  alias Jido.Cluster.HostSession

  @doc "Prepares durable host intent and closes provider admission before effects."
  @spec prepare(map(), atom(), node(), String.t()) :: {:ok, map(), map()} | {:error, term()}
  def prepare(state, action, host, id) do
    with {:ok, provider} <- configured(state.config, host),
         false <- Enum.any?(state.host_tasks, fn {_, task} -> task.host == host end),
         true <- state.recovery_task == nil,
         {:ok, session} <- intent(state, action, host, provider, id) do
      op = %{
        id: id,
        attempt_id: id,
        action: action,
        host: host,
        topology_id: nil,
        phase: :accepted,
        reason: nil,
        namespace: state.config.namespace,
        scope: state.config.scope
      }

      ledger = %{state.ledger | provider_pending: MapSet.put(state.ledger.provider_pending, host)}

      {:ok,
       %{
         state
         | ledger: ledger,
           host_sessions: Map.put(state.host_sessions, host, session),
           operations: Map.put(state.operations, id, op)
       }, op}
    else
      {:error, _} = error -> error
      _ -> {:error, :busy}
    end
  end

  @doc "Returns runtime configuration separately from durable session data."
  @spec context(map(), node()) :: {:ok, map()} | {:error, term()}
  def context(state, host) do
    with {:ok, provider} <- configured(state.config, host),
         {:ok, session} <- Map.fetch(state.host_sessions, host) do
      {:ok, %{config: state.config, provider: provider, session: session, host: host}}
    else
      :error -> {:error, :host_session_not_found}
      error -> error
    end
  end

  @doc "Reports recorded and possibly committed host intent without opening uncertain admission."
  @spec status(map(), node()) :: {:ok, map()} | {:error, :host_session_not_found}
  def status(state, host) do
    session = Map.get(state.host_sessions, host)
    pending = if state.pending, do: Map.get(state.pending.host_sessions, host)
    closed = state.store_status != :ready or MapSet.member?(state.ledger.provider_pending, host)

    if session || pending,
      do:
        {:ok,
         %{
           session: session,
           pending_session: pending,
           admission: if(closed, do: :closed, else: :open),
           journal: state.store_status
         }},
      else: {:error, :host_session_not_found}
  end

  @doc "Checks the actual accepted provider task or explicit recovery task."
  @spec authorized?(map(), node(), pid()) :: boolean()
  def authorized?(state, host, caller) do
    match?(%{pid: ^caller}, state.recovery_task) or
      Enum.any?(state.host_tasks, fn {_, task} -> task.host == host and task.pid == caller end)
  end

  @doc "Applies progress only to the same recorded step and accepted intent."
  @spec progress(map(), node(), HostSession.t()) :: {:ok, map()} | {:error, term()}
  def progress(state, host, session) do
    with %HostSession{} = prior <- Map.get(state.host_sessions, host),
         :ok <- HostSession.validate(session),
         true <-
           {session.step, session.ownership, session.desired, session.operation} ==
             {prior.step, prior.ownership, prior.desired, prior.operation},
         true <- not prior.attempted or session.attempted,
         true <- prior.resource == nil or (session.resource != nil and Resource.same?(prior.resource, session.resource)) do
      {:ok, put_in(state, [:host_sessions, host], session)}
    else
      _ -> {:error, :stale_host_step}
    end
  end

  @doc "Records the outcome and opens admission only after confirmed runtime readiness."
  @spec result(map(), node(), map()) :: map()
  def result(state, host, result) do
    session = Map.fetch!(state.host_sessions, host)
    phase = if result.phase == :completed or session.phase == :deleting, do: session.phase, else: result.phase
    session = %{session | phase: phase, reason: reason(result.reason)}

    pending =
      if phase == :ready,
        do: MapSet.delete(state.ledger.provider_pending, host),
        else: MapSet.put(state.ledger.provider_pending, host)

    operations = finish_operation(state.operations, session.operation, result)

    operations =
      if session.desired == :released and result.phase == :completed,
        do: finish_operation(operations, session.step.id, %{phase: :failed, reason: :released_before_ready}),
        else: operations

    %{
      state
      | host_sessions: Map.put(state.host_sessions, host, session),
        operations: operations,
        ledger: %{state.ledger | provider_pending: pending}
    }
  end

  defp finish_operation(operations, id, result) do
    case Map.get(operations, id) do
      %{phase: phase} = op when phase not in [:completed, :failed] -> Map.put(operations, id, Map.merge(op, result))
      _ -> operations
    end
  end

  defp configured(config, host) do
    case Map.fetch(config.host_providers, host) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :host_provider_not_configured}
    end
  end

  defp intent(state, :acquire_host, host, provider, id) do
    previous = Map.get(state.host_sessions, host)

    cond do
      host == node() and provider.ownership == :owned ->
        {:error, :control_host_cannot_be_owned}

      previous != nil and previous.phase not in [:released, :retained, :failed] ->
        {:error, :host_session_exists}

      true ->
        with {:ok, step} <-
               Step.new(%{
                 namespace: state.config.namespace,
                 scope: state.config.scope,
                 host: Atom.to_string(host),
                 provider: provider.id,
                 id: id
               }),
             do: HostSession.new(step, provider.ownership, id)
    end
  end

  defp intent(state, :release_host, host, _provider, id) do
    case Map.get(state.host_sessions, host) do
      nil ->
        {:error, :host_session_not_found}

      %{phase: :failed, resource: nil} ->
        {:error, :host_not_acquired}

      %{phase: phase} = session when phase in [:released, :retained] ->
        {:ok, %{session | operation: id, reason: nil}}

      %{desired: :released} ->
        {:error, :host_release_exists}

      session ->
        {:ok,
         %{
           session
           | desired: :released,
             phase: if(session.phase == :deleting, do: :deleting, else: :releasing),
             operation: id,
             reason: nil
         }}
    end
  end

  defp reason(nil), do: nil

  defp reason(reason) do
    reason
    |> inspect(limit: 16, printable_limit: 128, structs: false)
    |> String.codepoints()
    |> Enum.reduce_while("", fn point, acc ->
      if byte_size(acc) + byte_size(point) <= 512, do: {:cont, acc <> point}, else: {:halt, acc}
    end)
  end
end
