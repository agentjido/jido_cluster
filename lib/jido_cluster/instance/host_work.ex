defmodule Jido.Cluster.Instance.HostWork do
  @moduledoc false
  alias Jido.Cluster.HostProvider.{Release, Resource, Step}
  alias Jido.Cluster.{HostRuntime, HostSession}
  alias Jido.Cluster.Instance.Service

  @doc "Runs one recorded host step; unknown acquisition is inspected, never recreated."
  @spec run(pid(), node()) :: map()
  def run(owner, host) do
    with {:ok, c} <- Service.call(owner, {:host_context, host}),
         :ok <- run_intent(Map.put(c, :owner, owner)) do
      %{phase: :completed, reason: nil}
    else
      {:error, {:rejected, reason}} -> %{phase: :failed, reason: reason}
      {:error, reason} -> %{phase: :uncertain, reason: reason}
      other -> %{phase: :uncertain, reason: {:invalid_provider_result, other}}
    end
  catch
    kind, reason -> %{phase: :uncertain, reason: {:host_step_exit, kind, reason}}
  end

  @doc "Reconciles only recorded sessions with the requested desired state."
  @spec recover(pid(), :running | :released) :: :ok
  def recover(owner, desired) do
    {:ok, sessions} = Service.call(owner, :host_sessions)

    for {host, session} <- Enum.sort(sessions),
        session.desired == desired,
        session.phase not in [:released, :retained, :failed] do
      result = run(owner, host)
      Service.call(owner, {:host_recovery_result, host, session.step.id, result})
    end

    :ok
  end

  defp run_intent(%{session: %{desired: :released}} = c), do: release(c)
  defp run_intent(c), do: acquire(c)

  defp acquire(%{session: %{ownership: :owned, attempted: false}} = c) do
    session = %{c.session | attempted: true, phase: :acquiring}

    with :ok <- progress(c, session),
         {:ok, resource} <- c.provider.module.acquire(session.step, c.provider.options),
         do: acquired(%{c | session: session}, resource)
  end

  defp acquire(c) do
    case c.provider.module.inspect(c.session.step, c.provider.options) do
      {:ok, :absent} -> {:error, :acquisition_unresolved}
      {:ok, resource} -> acquired(c, resource)
      error -> error
    end
  end

  defp acquired(c, %Resource{step: step} = resource) when step == c.session.step do
    prior = c.session.resource

    if prior == nil or Resource.same?(prior, resource) do
      session = %{c.session | resource: resource, phase: :acquired, reason: nil}

      with :ok <- HostSession.validate(session),
           :ok <- progress(c, session),
           {:ok, info} <- runtime(c, resource),
           do: progress(c, %{session | phase: :ready, host_incarnation: info.incarnation})
    else
      {:error, :resource_identity_changed}
    end
  end

  defp acquired(_, _), do: {:error, :resource_identity_changed}

  defp runtime(c, %{state: :running}) do
    with true <- c.host == node() or Node.connect(c.host),
         {:ok, local} <- HostRuntime.probe(HostRuntime.name(c.config.jido), []),
         {:ok, remote} <-
           HostRuntime.probe(
             {HostRuntime.name(c.config.jido), c.host},
             runtime_requirements(c, local),
             c.config.timeout
           ),
         :ok <- allocation(c, remote) do
      {:ok, remote}
    else
      false -> {:error, :host_unreachable}
      error -> error
    end
  end

  defp runtime(_, _), do: {:error, :resource_not_running}

  defp runtime_requirements(c, local) do
    requirements = [
      namespace: c.config.namespace,
      protocol: 1,
      release: local.release,
      persistence_identity: local.persistence_identity
    ]

    if c.session.ownership == :owned,
      do: Keyword.put(requirements, :provider_step, Step.to_record(c.session.step)),
      else: requirements
  end

  defp allocation(c, _remote) do
    candidate = Enum.find(c.config.hosts, &(&1.node == c.host))
    status = HostRuntime.status({HostRuntime.name(c.config.jido), c.host})
    scope = {c.config.namespace, c.config.scope}

    with true <- c.session.ownership == :borrowed or map_size(status.allocations) == 1,
         %{capacity: capacity, scope: prior_scope, retiring_step: nil} = allocation <-
           Map.get(status.allocations, candidate.allocation),
         true <- capacity in [nil, candidate.capacity] and prior_scope in [nil, scope] do
      register(c, candidate, status, allocation, scope)
    else
      _ -> {:error, :allocation_mismatch}
    end
  end

  defp register(c, candidate, status, allocation, scope) do
    host = {HostRuntime.name(c.config.jido), c.host}

    case HostRuntime.register(host, c.owner, scope, status.incarnation, candidate.allocation) do
      {:error, :reconciliation_required} when allocation.claims == [] ->
        HostRuntime.reconcile(host, c.owner, scope, status.incarnation, [], candidate.allocation)

      {:error, :reconciliation_required} ->
        :ok

      result ->
        result
    end
  end

  defp release(%{session: %{phase: phase}}) when phase in [:released, :retained], do: :ok

  defp release(%{session: %{ownership: :borrowed}} = c),
    do: progress(c, %{c.session | phase: :retained})

  defp release(c) do
    observation = c.provider.module.inspect(c.session.step, c.provider.options)

    with :ok <- same_resource(c.session.resource, observation),
         {:ok, evidence} <- cleanup_evidence(c, observation) do
      release_decision(c, Release.decide(c.session, observation, evidence))
    end
  end

  defp same_resource(%Resource{} = recorded, {:ok, %Resource{} = current}) do
    if Resource.same?(recorded, current), do: :ok, else: {:error, :resource_identity_changed}
  end

  defp same_resource(_, _), do: :ok

  defp release_decision(c, {:adopt, resource}) do
    session = %{c.session | resource: resource}
    with :ok <- progress(c, session), do: release(%{c | session: session})
  end

  defp release_decision(c, :released), do: progress(c, %{c.session | phase: :released})

  defp release_decision(c, {:release, resource}) do
    session = %{c.session | phase: :deleting}

    with :ok <- progress(c, session) do
      result = c.provider.module.release(resource, c.provider.options)

      case result do
        {:error, {:rejected, reason}} -> {:error, {:release_rejected, reason}}
        _ -> confirm_deletion(%{c | session: session})
      end
    end
  end

  defp release_decision(_, {:keep, reason}), do: {:error, reason}

  defp confirm_deletion(c) do
    case c.provider.module.inspect(c.session.step, c.provider.options) do
      {:ok, :absent} -> progress(c, %{c.session | phase: :released})
      {:ok, _} -> {:error, :release_unconfirmed}
      {:error, reason} -> {:error, {:release_inspection, reason}}
    end
  end

  defp cleanup_evidence(c, observation) do
    claims = Service.call(c.owner, :claims) |> Enum.filter(&(&1.host == c.host))

    with [] <- claims, :ok <- cleanup_receipt(c, observation) do
      {:ok, %{claims: [], agents: :settled, bindings: :settled, admission: :closed}}
    else
      [_ | _] -> {:error, :claims_retained}
      error -> error
    end
  end

  defp cleanup_receipt(%{session: %{phase: :deleting}}, {:ok, :absent}), do: :ok
  defp cleanup_receipt(%{session: %{resource: %Resource{}}}, {:ok, :absent}), do: :ok
  defp cleanup_receipt(c, _), do: runtime_empty(c)

  defp runtime_empty(%{session: %{host_incarnation: nil}}), do: :ok

  defp runtime_empty(c) do
    status = HostRuntime.status({HostRuntime.name(c.config.jido), c.host})
    claims = Enum.flat_map(status.allocations, fn {_, allocation} -> allocation.claims end)

    agents =
      :erpc.call(
        c.host,
        DynamicSupervisor,
        :count_children,
        [Jido.agent_supervisor_name(c.config.jido)],
        c.config.timeout
      )

    mirrors =
      :erpc.call(c.host, DynamicSupervisor, :count_children, [Jido.Cluster.FederationSupervisor], c.config.timeout)

    candidate = Enum.find(c.config.hosts, &(&1.node == c.host))
    allocation = Map.get(status.allocations, candidate.allocation)

    same =
      status.incarnation == c.session.host_incarnation or
        (allocation != nil and allocation.retiring_step == c.session.step.id)

    if same and map_size(status.allocations) == 1 and claims == [] and agents.active == 0 and mirrors.active == 0,
      do:
        HostRuntime.retire(
          {HostRuntime.name(c.config.jido), c.host},
          c.owner,
          {c.config.namespace, c.config.scope},
          status.incarnation,
          c.session.step.id,
          candidate.allocation
        ),
      else: {:error, :host_cleanup_unconfirmed}
  end

  defp progress(c, session), do: Service.call(c.owner, {:host_progress, c.host, session})
end
