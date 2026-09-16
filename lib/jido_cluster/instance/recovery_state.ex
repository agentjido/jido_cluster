defmodule Jido.Cluster.Instance.RecoveryState do
  @moduledoc false
  alias Jido.Cluster.{Activation, Admission, Drain}
  alias Jido.Cluster.Federation.Intent

  @doc "Reports whether stored uncertainty needs an explicit recovery pass."
  @spec needed?(map()) :: boolean()
  def needed?(state) do
    state.store_status != :ready or
      Enum.any?(state.deployments, fn {_, d} -> d.phase == :uncertain or Map.get(d, :recovery, :idle) != :idle end) or
      Enum.any?(state.operations, fn {_, op} -> op.phase in [:accepted, :uncertain] end) or
      Enum.any?(Map.get(state, :host_sessions, %{}), fn {host, session} ->
        session.phase not in [:released, :retained, :failed] and
          (session.phase != :ready or MapSet.member?(state.ledger.provider_pending, host))
      end)
  end

  @doc "Returns a recorded recovery target and the full scope claim set."
  @spec target(map(), String.t()) :: {:ok, map(), [map()]} | {:error, atom()}
  def target(state, id) do
    case Map.get(state.deployments, id) do
      %{recovery: :pending} = d -> {:ok, %{d | selected: selected(state, d)}, Admission.claims(state.ledger)}
      _ -> {:error, :stale_recovery}
    end
  end

  @doc "Records a replacement within the already admitted reservation after confirmed cleanup."
  @spec prepare(map(), String.t(), String.t()) :: {:ok, map(), map()} | {:error, term()}
  def prepare(state, id, previous) do
    with {:ok, d, _claims} <- target(state, id),
         true <- d.activation.id == previous do
      prepare_desired(state, d)
    else
      false -> {:error, :stale_recovery}
      error -> error
    end
  end

  @doc "Checks that no unresolved claim shares a replacement host."
  @spec candidate(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def candidate(state, id) do
    with {:ok, d, claims} <- target(state, id) do
      blocked = Enum.filter(claims, &(&1.host in Map.values(d.selected) and &1.state == :uncertain))
      pending = Enum.filter(Map.values(d.selected), &MapSet.member?(state.ledger.provider_pending, &1))

      cond do
        pending != [] -> {:error, {:host_provider_pending, Enum.sort(Enum.uniq(pending))}}
        blocked != [] -> {:error, {:resources_uncertain, Enum.map(blocked, & &1.id)}}
        true -> {:ok, d}
      end
    end
  end

  @doc "Records a recovery result without replacing historical request identity."
  @spec result(map(), String.t(), map()) :: map()
  def result(state, id, %{phase: :completed} = result) do
    d = Map.fetch!(state.deployments, id)
    d = d |> Map.merge(result) |> Map.merge(%{recovery: :idle, recovery_hosts: %{}})

    state = %{
      state
      | deployments: Map.put(state.deployments, id, d),
        ledger: completed_claims(state.ledger, d)
    }

    settle_latest(state, d, :completed, nil)
  end

  def result(state, id, result) do
    d = Map.fetch!(state.deployments, id)
    phase = if d.phase == :accepted, do: :uncertain, else: d.phase
    d = Map.merge(d, %{recovery: :uncertain, phase: phase, reason: result.reason})

    state = %{
      state
      | deployments: Map.put(state.deployments, id, d),
        ledger: Admission.uncertain_deployment(state.ledger, id)
    }

    settle_latest(state, d, :uncertain, result.reason)
  end

  @doc "Parks any unfinished recovery after task loss."
  @spec interrupt(map(), term()) :: map()
  def interrupt(state, reason) do
    Enum.reduce(state.deployments, state, fn {id, d}, acc ->
      if Map.get(d, :recovery) == :pending, do: result(acc, id, %{phase: :uncertain, reason: reason}), else: acc
    end)
  end

  @doc "Settles drain steps and superseded operations from confirmed deployment outcomes."
  @spec finish(map()) :: map()
  def finish(state) do
    operations = Map.new(state.operations, fn {id, op} -> {id, finish_operation(op, state.deployments)} end)
    %{state | operations: operations}
  end

  defp prepare_desired(state, %{desired: :stopped} = d) do
    {:ok, ledger} = Admission.release(state.ledger, d.instance.id, :confirmed)
    d = Map.merge(d, %{phase: :completed, recovery: :idle, recovery_hosts: %{}, runner: nil, reason: nil})
    d = Map.put(d, :federation, Intent.stopped(Map.get(d, :federation)))
    d = Map.put(d, :federation_transition, nil)
    next = %{state | ledger: ledger, deployments: Map.put(state.deployments, d.instance.id, d)}
    {:ok, settle_latest(next, d, :completed, nil), d}
  end

  defp prepare_desired(state, d) do
    activation = Activation.new(state.ledger.scope, d.instance.id)
    demand = Drain.demand(d.instance, state.config.namespace, d.selected)
    # Retain the full admitted transition. Core can restore the recorded source
    # before it completes a move whose target has not yet been accepted.
    with {:ok, claims} <- replacement_claims(state.ledger, d.instance.id, demand, activation.id),
         {:ok, federation} <- Intent.replacement(%{d | activation: activation}) do
      {:ok, ledger} = Admission.release(state.ledger, d.instance.id, :confirmed)

      ledger = %{
        ledger
        | claims: Map.merge(ledger.claims, claims),
          requests: Map.merge(ledger.requests, reservations(claims))
      }

      d = d |> Map.merge(%{activation: activation, runner: nil, reason: nil}) |> Map.put(:federation, federation)
      d = Map.put(d, :federation_transition, nil)
      {:ok, %{state | ledger: ledger, deployments: Map.put(state.deployments, d.instance.id, d)}, d}
    end
  end

  defp replacement_claims(ledger, id, demand, operation) do
    if Enum.all?(demand, fn {ref, host} -> Map.has_key?(ledger.claims, {id, ref, host}) end) do
      claims =
        for {key, claim} <- ledger.claims, claim.topology_id == id, into: %{} do
          attempt = operation <> "/" <> Base.url_encode64(Atom.to_string(claim.host), padding: false)
          {key, %{claim | state: :reserved, host_incarnation: nil, operation_id: attempt}}
        end

      {:ok, claims}
    else
      {:error, :missing_recovery_reservation}
    end
  end

  defp reservations(claims) do
    claims
    |> Map.values()
    |> Enum.group_by(& &1.operation_id)
    |> Map.new(fn {id, [first | _] = claims} ->
      {id, {first.topology_id, Map.new(claims, &{&1.ref, &1.host})}}
    end)
  end

  defp completed_claims(ledger, d) do
    demand = Drain.demand(d.instance, elem(ledger.scope, 0), d.selected)

    retired =
      for claim <- Admission.claims(ledger),
          claim.topology_id == d.instance.id,
          Map.get(demand, claim.ref) != claim.host,
          into: %{},
          do: {claim.ref, claim.host}

    {:ok, ledger} = Admission.retire(ledger, d.instance.id, retired, :confirmed)

    claims =
      Map.new(ledger.claims, fn {id, claim} ->
        {id, if(claim.topology_id == d.instance.id, do: %{claim | state: :active}, else: claim)}
      end)

    %{ledger | claims: claims}
  end

  defp selected(state, d) do
    case Map.get(state.operations, d.operation) do
      %{action: :drain, steps: steps} -> Map.fetch!(steps, d.instance.id).selected
      _ -> d.selected
    end
  end

  defp settle_latest(state, d, phase, reason) do
    case Map.get(state.operations, d.operation) do
      %{action: action, phase: old} = op when action in [:deploy, :stop] and old in [:accepted, :uncertain] ->
        %{state | operations: Map.put(state.operations, op.id, %{op | phase: phase, reason: reason})}

      _ ->
        state
    end
  end

  defp finish_operation(%{phase: phase} = op, _) when phase in [:completed, :failed], do: op

  defp finish_operation(%{action: :drain} = op, deployments) do
    steps =
      Map.new(op.steps, fn {id, step} ->
        complete = settled?(Map.fetch!(deployments, id), step)
        {id, if(complete, do: %{step | phase: :completed}, else: step)}
      end)

    complete =
      Enum.all?(steps, fn {id, step} -> step.phase == :completed and settled?(Map.fetch!(deployments, id), step) end)

    %{
      op
      | steps: steps,
        phase: if(complete, do: :completed, else: :uncertain),
        reason: if(complete, do: nil, else: :recovery_incomplete)
    }
  end

  defp finish_operation(op, deployments) do
    case Map.get(deployments, op.topology_id) do
      %{desired: :stopped, phase: :completed, recovery: :idle} ->
        %{op | phase: if(op.action == :stop, do: :completed, else: :failed), reason: :stopped_intent}

      _ ->
        op
    end
  end

  defp settled?(d, step),
    do: d.recovery == :idle and d.phase == :completed and (d.desired == :stopped or d.selected == step.selected)
end
