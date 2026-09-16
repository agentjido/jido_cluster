defmodule Jido.Cluster.Instance.Store do
  @moduledoc false
  alias Jido.Cluster.{Admission, Journal}
  alias Jido.Cluster.Journal.Snapshot

  @doc "Restores intent and confirms a revision before the service accepts work."
  @spec open(map()) :: {:ok, map()} | {:error, term()}
  def open(%{config: %{journal: :memory}} = state), do: {:ok, initialize(state, nil)}

  def open(state) do
    with {:ok, journal} <- Journal.open(state.config.journal, {state.config.namespace, state.config.scope}),
         {:ok, state} <- restore(initialize(state, journal)),
         {:ok, record} <- Snapshot.encode(state, state.config.registry, :observation),
         {:ok, journal} <- Journal.commit(journal, record) do
      {:ok, %{state | journal: journal}}
    else
      {:error, reason, _} -> {:error, {:journal_write_failed, reason}}
      error -> error
    end
  end

  @doc "Reports whether a new mutation may use this journal and recovered state."
  @spec writable(map()) :: :ok | {:error, atom()}
  def writable(%{store_status: :ready}), do: :ok
  def writable(state), do: {:error, state.store_status}

  @doc "Rereads and confirms a new revision before recovery can submit an external step."
  @spec recover(map()) :: {:ok, map()} | {:error, term(), map()}
  def recover(%{journal: nil} = state), do: {:error, :journal_required, state}

  def recover(state) do
    with {:ok, journal} <- Journal.reload(state.journal),
         {:ok, restored} <- restore(%{state | journal: journal, pending: nil}),
         ready = %{restored | store_status: :ready},
         {:ok, record} <- Snapshot.encode(ready, state.config.registry, :observation),
         {:ok, committed} <- Journal.commit(journal, record) do
      {:ok, %{ready | journal: committed}}
    else
      {:error, reason, journal} ->
        {:error, {:journal_write_failed, reason}, %{state | journal: journal, store_status: :journal_unavailable}}

      {:error, reason} ->
        {:error, reason, %{state | store_status: :journal_unavailable}}
    end
  end

  @doc "Writes a candidate before acknowledgement; retains uncertainty after unknown results."
  @spec persist(map(), map(), :admission | :observation) :: {:ok, map()} | {:error, term(), map()}
  def persist(current, candidate, stage \\ :observation)

  def persist(%{store_status: status} = current, _candidate, _) when status != :ready,
    do: {:error, status, current}

  def persist(%{journal: nil}, candidate, _), do: {:ok, candidate}

  def persist(current, candidate, stage) do
    with {:ok, record} <- Snapshot.encode(candidate, current.config.registry, stage),
         {:ok, journal} <- Journal.commit(current.journal, record) do
      {:ok, %{candidate | journal: journal, pending: nil}}
    else
      {:error, reason, journal} ->
        failed =
          if journal.status == :ready and stage == :admission, do: current, else: block(current, candidate, journal)

        {:error, {:journal_write_failed, reason}, failed}

      {:error, reason} ->
        failed = if stage == :admission, do: current, else: block(current, candidate, current.journal)
        {:error, reason, failed}
    end
  end

  @doc "Keeps possible claims visible while an unknown record awaits reconciliation."
  @spec claims(map()) :: [map()]
  def claims(%{pending: nil} = state), do: Admission.claims(state.ledger)

  def claims(state) do
    claims = Map.merge(state.pending.ledger.claims, state.ledger.claims)
    Admission.claims(%{state.ledger | claims: claims})
  end

  @doc "Builds request identity from portable intent when a journal is configured."
  @spec fingerprint(map(), atom(), term()) :: {:ok, binary()} | {:error, term()}
  def fingerprint(%{journal: nil}, action, input),
    do: {:ok, :crypto.hash(:sha256, :erlang.term_to_binary({action, input}, [:deterministic]))}

  def fingerprint(state, action, input), do: Snapshot.fingerprint(action, input, state.config.registry)

  defp initialize(state, journal),
    do: Map.merge(state, %{journal: journal, store_status: :ready, pending: nil})

  defp block(current, candidate, journal),
    do: %{current | journal: journal, store_status: :journal_unavailable, pending: candidate}

  defp restore(%{journal: %{record: nil}} = state), do: {:ok, state}

  defp restore(state) do
    with {:ok, restored} <- Snapshot.decode(state.journal.record, state.config, state.config.registry) do
      required =
        map_size(restored.ledger.claims) > 0 or
          Enum.any?(restored.host_sessions, fn {_, session} -> session.phase not in [:released, :retained, :failed] end) or
          Enum.any?(restored.deployments, fn {_, d} -> d.desired == :running or d.phase != :completed end) or
          Enum.any?(restored.operations, fn {_, op} -> op.phase not in [:completed, :failed] end)

      restored = mark_recovery(restored)

      {:ok,
       state |> Map.merge(restored) |> Map.put(:store_status, if(required, do: :reconciliation_required, else: :ready))}
    end
  end

  defp mark_recovery(state) do
    Enum.reduce(state.deployments, state, fn {id, deployment}, acc ->
      claims = Enum.any?(state.ledger.claims, fn {_, claim} -> claim.topology_id == id end)

      if deployment.desired == :running or deployment.phase != :completed or deployment.recovery != :idle or claims do
        d = Map.merge(deployment, %{recovery: :pending, recovery_hosts: %{}, runner: nil})
        %{acc | deployments: Map.put(acc.deployments, id, d), ledger: Admission.uncertain_deployment(acc.ledger, id)}
      else
        acc
      end
    end)
  end
end
