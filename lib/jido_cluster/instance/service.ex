defmodule Jido.Cluster.Instance.Service do
  @moduledoc false
  use GenServer
  alias Jido.Cluster.{Activation, Admission, Deployment, Drain, Entity, Instance, Journal, Placement}
  alias Jido.Cluster.Federation.{Intent, Runtime}

  alias Jido.Cluster.Instance.{
    BindingRepair,
    DrainWork,
    FederationMove,
    HostControl,
    HostWork,
    Recovery,
    RecoveryState,
    Retention,
    Store,
    Work
  }

  alias Jido.Cluster.Deployment.Planner
  alias Jido.Topology.Plan

  @doc "Starts the connected scope authority."
  @spec start_link(Instance.Config.t()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: Instance.name(config.name, Service))
  @doc "Submits a public facade request to its named instance."
  @spec call(atom() | pid(), term(), timeout()) :: term()
  def call(instance, request, timeout \\ 5_000)
  def call(owner, request, timeout) when is_pid(owner), do: GenServer.call(owner, request, timeout)
  def call(instance, request, timeout), do: GenServer.call(Instance.name(instance, Service), request, timeout)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    {:ok, ledger} = Admission.new({config.namespace, config.scope}, config.hosts)
    ledger = %{ledger | provider_pending: MapSet.new(Map.keys(config.host_providers))}
    key = {__MODULE__, config.namespace, config.scope}
    :ok = :global.sync()

    case :global.register_name(key, self()) do
      :yes ->
        state = %{
          config: config,
          ledger: ledger,
          key: key,
          core: Process.monitor(config.jido),
          generation: Jido.generate_id(),
          epoch: 0,
          operations: %{},
          requests: %{},
          deployments: %{},
          host_sessions: %{},
          host_tasks: %{},
          tasks: %{},
          waiters: %{},
          recovery_task: nil
        }

        case Store.open(state) do
          {:ok, state} -> {:ok, state}
          {:error, reason} -> {:stop, reason}
        end

      :no ->
        {:stop, {:scope_already_owned, :global.whereis_name(key)}}
    end
  end

  @impl true
  def handle_call(:config, _from, state), do: {:reply, {:ok, state.config}, state}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       mode: state.config.mode,
       namespace: state.config.namespace,
       scope: state.config.scope,
       durability: if(state.journal, do: :journal, else: :memory_only),
       limits: Journal.limits(),
       retention: Retention.status(state),
       recovering: state.recovery_task != nil,
       status: state.store_status
     }, state}
  end

  def handle_call(:claims, _from, state), do: {:reply, Store.claims(state), state}

  def handle_call(:host_sessions, _from, state), do: {:reply, {:ok, state.host_sessions}, state}

  def handle_call({:host_status, host}, _from, state), do: {:reply, HostControl.status(state, host), state}

  def handle_call({:host_context, host}, _from, state) do
    result = with :ok <- Store.writable(state), do: HostControl.context(state, host)
    {:reply, result, state}
  end

  def handle_call({:host_progress, host, session}, {caller, _}, state) do
    with :ok <- Store.writable(state),
         true <- HostControl.authorized?(state, host, caller),
         {:ok, next} <- HostControl.progress(state, host, session) do
      persist_reply(state, next, :ok)
    else
      false -> {:reply, {:error, :stale_host_task}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:host_recovery_result, host, step, result}, {caller, _}, %{recovery_task: %{pid: caller}} = state) do
    case Map.get(state.host_sessions, host) do
      %{step: %{id: ^step}} -> persist_reply(state, HostControl.result(state, host, result), :ok)
      _ -> {:reply, {:error, :stale_host_step}, state}
    end
  end

  def handle_call({:host_recovery_result, _, _, _}, _, state), do: {:reply, {:error, :stale_host_task}, state}

  def handle_call({:host_request, action, host, token}, _from, state) when action in [:acquire_host, :release_host] do
    with :ok <- valid_token(state, token),
         {:ok, fingerprint} <- Store.fingerprint(state, action, host),
         :new <- replay(state, token, fingerprint),
         :ok <- Store.writable(state),
         :ok <- Retention.admit(state, :accepted),
         {:ok, next, op} <- HostControl.prepare(state, action, host, Jido.generate_id()) do
      next = %{next | requests: Map.put(next.requests, token, {fingerprint, op.id})}
      owner = self()
      accept_work(state, next, op, [], fn -> HostWork.run(owner, host) end)
    else
      result -> {:reply, result, state}
    end
  end

  def handle_call(:reconcile, _from, state) do
    cond do
      map_size(state.tasks) != 0 or state.recovery_task != nil ->
        {:reply, {:error, :busy}, state}

      not RecoveryState.needed?(state) and not runtime_recovery?(state) ->
        start_binding_repair(state)

      true ->
        start_recovery(state)
    end
  end

  def handle_call({:recovery_target, id}, _from, state) do
    result = with :ok <- Store.writable(state), do: RecoveryState.target(state, id)
    {:reply, result, state}
  end

  def handle_call({:recovery_candidate, id}, _from, state) do
    result = with :ok <- Store.writable(state), do: RecoveryState.candidate(state, id)
    {:reply, result, state}
  end

  def handle_call({:recovery_host, id, host, incarnation}, _from, state) do
    deployments =
      Map.update!(state.deployments, id, fn d -> %{d | recovery_hosts: Map.put(d.recovery_hosts, host, incarnation)} end)

    persist_reply(state, %{state | deployments: deployments}, :ok)
  end

  def handle_call({:recovery_prepare, id, previous}, _from, state) do
    with :ok <- Store.writable(state), {:ok, next, d} <- RecoveryState.prepare(state, id, previous) do
      persist_reply(state, next, {:ok, d})
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:recovery_result, id, result}, _from, state),
    do: persist_reply(state, RecoveryState.result(state, id, result), :ok)

  def handle_call({:binding_repair_prepare, id}, {caller, _}, %{recovery_task: %{pid: caller, kind: :bindings}} = state) do
    with :ok <- Store.writable(state),
         %{desired: :running, phase: :completed, recovery: :idle} = d <- Map.get(state.deployments, id),
         true <- current_readiness(d.runner) == :ready,
         {:ok, d} <- FederationMove.repair(state.config, d) do
      d = d |> Map.put(:binding_busy, true) |> Map.put(:reason, nil)
      persist_reply(state, put_in(state, [:deployments, id], d), {:ok, d}, :admission)
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :binding_target_changed}, state}
    end
  end

  def handle_call({:binding_repair_prepare, _}, _, state), do: {:reply, {:error, :stale_binding_repair}, state}

  def handle_call(
        {:binding_repair_result, id, activation, revision, result},
        {caller, _},
        %{recovery_task: %{pid: caller, kind: :bindings}} = state
      ) do
    with %{activation: ^activation, binding_busy: true} = d <- Map.get(state.deployments, id),
         true <- d.federation["revision"] === revision do
      d = finish_binding(d, result)
      persist_reply(state, put_in(state, [:deployments, id], d), :ok)
    else
      _ -> {:reply, {:error, :stale_binding_repair}, state}
    end
  end

  def handle_call({:binding_repair_result, _, _, _, _}, _, state),
    do: {:reply, {:error, :stale_binding_repair}, state}

  def handle_call(
        {:binding_repair_refused, id, reason},
        {caller, _},
        %{recovery_task: %{pid: caller, kind: :bindings}} = state
      ) do
    case Map.get(state.deployments, id) do
      %{desired: :running, phase: :completed} = d ->
        persist_reply(state, put_in(state, [:deployments, id], %{d | reason: {:binding_repair, reason}}), :ok)

      _ ->
        {:reply, {:error, :stale_binding_repair}, state}
    end
  end

  def handle_call({:binding_repair_refused, _, _}, _, state),
    do: {:reply, {:error, :stale_binding_repair}, state}

  def handle_call(:request_id, _from, state) do
    with :ok <- Store.writable(state),
         {:ok, next} <- Retention.rotate(state) do
      token = %{
        scope: {next.config.namespace, next.config.scope},
        generation: next.generation,
        epoch: next.epoch,
        nonce: Jido.generate_id()
      }

      if next.epoch == state.epoch, do: {:reply, token, state}, else: persist_reply(state, next, token)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:plan, topology}, _from, state), do: {:reply, plan(state, topology), state}
  def handle_call({:operation, id}, _from, state), do: {:reply, fetch(state.operations, id), state}

  def handle_call({:enable_host, host, token}, _from, state) do
    with :ok <- valid_token(state, token),
         {:ok, fingerprint} <- Store.fingerprint(state, :enable_host, host),
         :new <- replay(state, token, fingerprint),
         :ok <- Store.writable(state),
         :ok <- Retention.admit(state, :completed),
         :ok <- can_enable(state, host) do
      id = Jido.generate_id()

      operation = %{
        id: id,
        attempt_id: Jido.generate_id(),
        action: :enable_host,
        host: host,
        topology_id: nil,
        phase: :completed,
        reason: nil,
        namespace: state.config.namespace,
        scope: state.config.scope
      }

      next = %{
        state
        | ledger: Admission.enable(state.ledger, host),
          operations: Map.put(state.operations, id, operation),
          requests: Map.put(state.requests, token, {fingerprint, id})
      }

      persist_reply(state, next, {:ok, operation}, :admission)
    else
      result -> {:reply, result, state}
    end
  end

  def handle_call({:drain, host, token}, _from, state) do
    id = Jido.generate_id()

    with :ok <- valid_token(state, token),
         {:ok, fingerprint} <- Store.fingerprint(state, :drain, host),
         :new <- replay(state, token, fingerprint),
         :ok <- Store.writable(state),
         :ok <- Retention.admit(state, :accepted),
         {:ok, ledger, steps} <- Drain.plan(state.ledger, state.deployments, host, id),
         {:ok, deployments} <- FederationMove.prepare(state, steps, id),
         :ok <- Retention.claims(ledger) do
      op = %{
        id: id,
        attempt_id: Jido.generate_id(),
        action: :drain,
        host: host,
        topology_id: nil,
        phase: :accepted,
        reason: nil,
        namespace: state.config.namespace,
        scope: state.config.scope,
        steps:
          Map.new(steps, fn step ->
            {step.id, step |> Map.take([:operation_id, :selected, :arrivals, :retired]) |> Map.put(:phase, :accepted)}
          end)
      }

      owner = self()
      claims = Enum.filter(Admission.claims(ledger), &Map.has_key?(op.steps, &1.topology_id))

      next = %{
        state
        | ledger: ledger,
          deployments: deployments,
          operations: Map.put(state.operations, id, op),
          requests: Map.put(state.requests, token, {fingerprint, id})
      }

      accept_work(state, next, op, claims, fn -> DrainWork.run(state.config, owner, id, steps) end)
    else
      result -> {:reply, result, state}
    end
  end

  def handle_call({:move_completed, parent, step}, _from, state) do
    {:ok, ledger} = Admission.retire(state.ledger, step.id, step.retired, :confirmed)
    ledger = Admission.mark(ledger, step.operation_id, :active)
    deployment = Map.fetch!(state.deployments, step.id)
    deployment = %{deployment | selected: step.selected, phase: :completed, reason: nil}
    op = Map.fetch!(state.operations, parent)
    op = put_in(op, [:steps, step.id, :phase], :completed)

    next = %{
      state
      | ledger: ledger,
        deployments: Map.put(state.deployments, step.id, deployment),
        operations: Map.put(state.operations, parent, op)
    }

    persist_reply(state, next, :ok)
  end

  def handle_call({:entity_ensure, topology}, _from, state), do: entity_ensure(state, topology)

  def handle_call({:entity_lookup, topology}, _from, state) do
    result =
      with true <- Entity.topology?(topology),
           :ok <- entity_identity(topology),
           :ok <- entity_readable(state),
           :ok <- entity_definition(state, topology) do
        spec = Map.fetch!(topology.plan.agents, "agent/entity")
        {:ok, ref} = Jido.agent_ref(state.config.jido, spec.id)
        lookup(state, ref)
      else
        false -> {:error, :invalid_entity_topology}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:submit, action, input, token}, _from, state), do: submit(state, action, input, token)

  def handle_call({:await, id, timeout}, from, state) do
    case fetch(state.operations, id) do
      {:ok, %{phase: :accepted}} when state.store_status != :ready ->
        {:reply, {:error, state.store_status}, state}

      {:ok, %{phase: :accepted}} ->
        ref = make_ref()
        timer = Process.send_after(self(), {:await_timeout, ref}, timeout)
        {:noreply, %{state | waiters: Map.put(state.waiters, ref, {id, from, timer})}}

      result ->
        {:reply, result, state}
    end
  end

  def handle_call({:deployment, id}, _from, state) do
    result =
      with {:ok, deployment} <- fetch(state.deployments, id), do: {:ok, observation(deployment, state.store_status)}

    {:reply, result, state}
  end

  def handle_call({:federation_context, id}, _from, state) do
    result =
      with {:ok, deployment} <- fetch(state.deployments, id) do
        {:ok,
         %{
           deployment: deployment,
           config: state.config,
           control_node: node(),
           store_status: state.store_status,
           observation: observation(deployment, state.store_status)
         }}
      end

    {:reply, result, state}
  end

  def handle_call({:ref, id, key}, _from, state) do
    result =
      with {:ok, deployment} <- fetch(state.deployments, id),
           plan_key = Plan.resolve(deployment.instance.plan, key, :agent),
           {:ok, agent} <- fetch(deployment.instance.plan.agents, plan_key),
           do: Jido.agent_ref(state.config.jido, agent.id)

    {:reply, result, state}
  end

  def handle_call({:lookup, _ref}, _from, %{store_status: status} = state) when status != :ready,
    do: {:reply, {:error, :uncertain}, state}

  def handle_call({:lookup, ref}, _from, state), do: {:reply, lookup(state, ref), state}

  def handle_call({:confirm_host, operation, host, incarnation}, _from, state) do
    case Admission.bind_host(state.ledger, operation, host, incarnation) do
      {:ok, ledger, claims} -> persist_reply(state, %{state | ledger: ledger}, {:ok, claims})
      error -> {:reply, error, state}
    end
  end

  def handle_call({:federation_attaching, id, activation, selected, revision}, _from, state) do
    with :ok <- Store.writable(state),
         %{activation: ^activation, selected: ^selected, desired: :running, federation: intent} = d <-
           Map.get(state.deployments, id),
         true <- intent["revision"] == revision,
         true <- is_nil(Map.get(d, :federation_transition)) or d.federation_transition["phase"] == "retired",
         {:ok, intent} <- Intent.attaching(intent, id, Admission.claims(state.ledger)) do
      next = put_in(state, [:deployments, id], %{d | federation: intent})
      persist_reply(state, next, {:ok, intent})
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :stale_binding_intent}, state}
    end
  end

  def handle_call({:federation_ready, id, activation, intent}, _from, state) do
    with :ok <- Store.writable(state),
         %{activation: ^activation, desired: :running, federation: ^intent} = d <- Map.get(state.deployments, id),
         true <- intent["phase"] in ["attaching", "ready"] do
      d = d |> Map.put(:federation, Intent.ready(intent)) |> Map.put(:federation_transition, nil)
      persist_reply(state, put_in(state, [:deployments, id], d), :ok)
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :stale_binding_intent}, state}
    end
  end

  def handle_call({:federation_guard, id, parent, selected}, _from, state) do
    with :ok <- Store.writable(state),
         %{operation: ^parent} = d <- Map.get(state.deployments, id),
         %{selected: ^selected} <- get_in(state.operations, [parent, :steps, id]) do
      {:reply,
       {:ok,
        %{
          activation: d.activation,
          initial_selected: d.initial_selected,
          binding_revision: get_in(d, [:federation, "revision"])
        }}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :stale_binding_intent}, state}
    end
  end

  def handle_call({:federation_transition, id, activation, revision, current, desired}, _from, state) do
    with :ok <- Store.writable(state),
         %{activation: ^activation, selected: ^desired, desired: :running, federation: intent} = d <-
           Map.get(state.deployments, id),
         true <- intent["revision"] === revision,
         transition = Map.get(d, :federation_transition),
         true <- transition != nil or current == desired or intent["phase"] == "planned" do
      {:reply, {:ok, intent, transition}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :stale_binding_intent}, state}
    end
  end

  def handle_call({:federation_retired, id, activation, intent, transition}, _from, state) do
    with :ok <- Store.writable(state),
         %{activation: ^activation, desired: :running, federation: ^intent, federation_transition: ^transition} = d <-
           Map.get(state.deployments, id) do
      d = %{d | federation_transition: %{transition | "phase" => "retired"}}
      persist_reply(state, put_in(state, [:deployments, id], d), :ok)
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :stale_binding_intent}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{core: ref} = state),
    do: {:stop, {:core_lost, reason}, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{recovery_task: %{ref: ref, kind: :bindings}} = state),
    do: {:noreply, finish_binding_pass(state, {:error, {:binding_repair_exit, reason}})}

  def handle_info({ref, :ok}, %{recovery_task: %{ref: ref, kind: :bindings}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_binding_pass(state, {:error, :binding_repair_interrupted})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{recovery_task: %{ref: ref}} = state),
    do: {:noreply, finish_recovery(state, {:recovery_exit, reason})}

  def handle_info({ref, :ok}, %{recovery_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_recovery(state, :ok)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, finish(state, ref, %{phase: :uncertain, reason: {:task_exit, reason}})}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  def handle_info({:await_timeout, ref}, state) do
    {waiter, waiters} = Map.pop(state.waiters, ref)
    if waiter, do: GenServer.reply(elem(waiter, 1), {:error, :timeout})
    {:noreply, %{state | waiters: waiters}}
  end

  defp submit(state, action, input, token) do
    id = Jido.generate_id()

    with :ok <- valid_token(state, token),
         {:ok, fingerprint} <- Store.fingerprint(state, action, input),
         :new <- replay(state, token, fingerprint),
         :ok <- Store.writable(state),
         :ok <- Retention.admit(state, :accepted),
         {:ok, deployment} <- prepare(state, action, input),
         {:ok, ledger} <- reserve(state, action, deployment, id) do
      op = %{
        id: id,
        attempt_id: Jido.generate_id(),
        action: action,
        topology_id: deployment.instance.id,
        phase: :accepted,
        reason: nil,
        namespace: state.config.namespace,
        scope: state.config.scope
      }

      owner = self()
      deployment = Map.put(deployment, :operation, id)
      claims = Enum.filter(Admission.claims(ledger), &(&1.topology_id == op.topology_id))

      next = %{
        state
        | ledger: ledger,
          operations: Map.put(state.operations, id, op),
          requests: Map.put(state.requests, token, {fingerprint, id}),
          deployments: Map.put(state.deployments, deployment.instance.id, deployment)
      }

      accept_work(state, next, op, claims, fn -> execute(action, state.config, deployment, owner, claims) end)
    else
      result -> {:reply, result, state}
    end
  end

  defp entity_ensure(state, topology) do
    with true <- Entity.topology?(topology),
         :ok <- entity_identity(topology),
         :ok <- Store.writable(state) do
      case Map.get(state.deployments, topology.id) do
        nil -> new_entity(state, topology)
        %{instance: existing, desired: :running} = deployment -> existing_entity(state, topology, existing, deployment)
        _ -> {:reply, {:error, :entity_stopped}, state}
      end
    else
      false -> {:reply, {:error, :invalid_entity_topology}, state}
      error -> {:reply, error, state}
    end
  end

  defp new_entity(state, topology) do
    if entity_count(state) < Entity.limits().active_per_scope do
      token = %{
        scope: {state.config.namespace, state.config.scope},
        generation: state.generation,
        epoch: state.epoch,
        nonce: Jido.generate_id()
      }

      case submit(state, :deploy, topology, token) do
        {:reply, {:ok, operation}, next} ->
          {:reply, {:ok, entity_result(next, topology, operation, :accepted)}, next}

        result ->
          result
      end
    else
      {:reply, {:error, :entity_limit}, state}
    end
  end

  defp existing_entity(state, topology, existing, deployment) do
    if existing.definition == topology.definition and existing.input == topology.input do
      operation =
        Map.get(state.operations, deployment.operation) ||
          %{id: deployment.operation, phase: deployment.phase, reason: deployment.reason}

      {:reply, {:ok, entity_result(state, topology, operation, :existing)}, state}
    else
      {:reply, {:error, :entity_definition_conflict}, state}
    end
  end

  defp entity_identity(topology) do
    info = topology.definition.metadata["jido.cluster.entity"]

    case Entity.Identity.parse(topology.id) do
      {:ok, %{definition_id: id}} ->
        if id == info["definition_id"], do: :ok, else: {:error, :invalid_entity_topology}

      _ ->
        {:error, :invalid_entity_topology}
    end
  end

  defp entity_count(state) do
    Enum.count(state.deployments, fn {_, deployment} ->
      deployment.desired == :running and Entity.topology?(deployment.instance)
    end)
  end

  defp entity_definition(state, topology) do
    case Map.get(state.deployments, topology.id) do
      nil ->
        {:error, :not_found}

      %{instance: existing} ->
        if existing.definition == topology.definition and existing.input == topology.input,
          do: :ok,
          else: {:error, :entity_definition_conflict}
    end
  end

  defp entity_readable(%{store_status: :ready}), do: :ok
  defp entity_readable(_), do: {:error, :uncertain}

  defp entity_result(state, topology, operation, status) do
    spec = Map.fetch!(topology.plan.agents, "agent/entity")
    {:ok, ref} = Jido.agent_ref(state.config.jido, spec.id)
    %{operation: operation, ref: ref, status: status, topology_id: topology.id}
  end

  defp start_work(config, operation, claims, work) do
    Task.Supervisor.async_nolink(Instance.name(config.name, Operations), fn ->
      Work.observe(operation, claims, work)
    end)
  end

  defp persist_reply(state, next, reply, stage \\ :observation) do
    case Store.persist(state, next, stage) do
      {:ok, saved} -> {:reply, reply, saved}
      {:error, reason, failed} -> {:reply, {:error, reason}, failed}
    end
  end

  defp accept_work(state, next, op, claims, work) do
    case Store.persist(state, next, :admission) do
      {:ok, saved} ->
        task = start_work(saved.config, op, claims, work)

        host_tasks =
          if op.action in [:acquire_host, :release_host],
            do: Map.put(saved.host_tasks, task.ref, %{pid: task.pid, host: op.host}),
            else: saved.host_tasks

        {:reply, {:ok, op}, %{saved | tasks: Map.put(saved.tasks, task.ref, op.id), host_tasks: host_tasks}}

      {:error, reason, failed} ->
        {:reply, {:error, reason}, failed}
    end
  end

  defp execute(:deploy, config, deployment, owner, _claims),
    do: Work.deploy(config, deployment, owner)

  defp execute(:stop, _config, %{runner: nil, prior_phase: :uncertain}, _owner, _claims),
    do: %{phase: :uncertain, reason: :cleanup_uncertain, runner: nil}

  defp execute(:stop, config, deployment, owner, claims),
    do: Work.stop(config, deployment, owner, Enum.filter(claims, &(&1.topology_id == deployment.instance.id)))

  defp can_enable(state, host) do
    claims = Enum.filter(Admission.claims(state.ledger), &(&1.host == host and &1.state == :uncertain))

    draining =
      Enum.any?(state.operations, fn {_, op} ->
        op.action == :drain and op.host == host and op.phase == :accepted
      end)

    cond do
      not Map.has_key?(state.ledger.hosts, host) -> {:error, :unknown_host}
      claims != [] -> {:error, {:resources_uncertain, Enum.map(claims, & &1.id)}}
      draining -> {:error, :drain_in_progress}
      true -> :ok
    end
  end

  defp valid_token(state, %{scope: scope, generation: generation, epoch: epoch, nonce: nonce} = token)
       when map_size(token) == 4 and is_integer(epoch) do
    cond do
      scope != {state.config.namespace, state.config.scope} -> {:error, :invalid_request_scope}
      generation != state.generation or epoch != state.epoch -> {:error, :expired_request}
      not is_binary(nonce) or byte_size(nonce) != 36 -> {:error, :invalid_request_id}
      true -> :ok
    end
  end

  defp valid_token(_, _), do: {:error, :invalid_request_id}

  defp replay(state, token, fingerprint) do
    case Map.get(state.requests, token) do
      nil -> :new
      {^fingerprint, id} -> fetch(state.operations, id)
      _ -> {:error, :request_conflict}
    end
  end

  defp reserve(state, :stop, _deployment, _id), do: {:ok, state.ledger}

  defp reserve(state, :deploy, deployment, id) do
    demand =
      Map.new(deployment.selected, fn {key, host} ->
        agent = Map.fetch!(deployment.instance.plan.agents, Plan.resolve(deployment.instance.plan, key, :agent))
        {:ok, ref} = Jido.agent_ref(state.config.jido, agent.id)
        {ref, host}
      end)

    with {:ok, ledger} <- Admission.reserve(state.ledger, deployment.instance.id, demand, id),
         :ok <- Retention.claims(ledger),
         do: {:ok, ledger}
  end

  defp settle(ledger, %{action: action}) when action in [:acquire_host, :release_host], do: ledger

  defp settle(ledger, %{action: :drain, steps: steps}) do
    Enum.reduce(steps, ledger, fn {id, step}, ledger ->
      if step.phase == :completed, do: ledger, else: Admission.uncertain_deployment(ledger, id)
    end)
  end

  defp settle(ledger, %{action: :stop, phase: :completed, topology_id: id}) do
    {:ok, ledger} = Admission.release(ledger, id, :confirmed)
    ledger
  end

  defp settle(ledger, %{action: :deploy, phase: :failed, topology_id: id}) do
    {:ok, ledger} = Admission.release(ledger, id, :confirmed)
    ledger
  end

  defp settle(ledger, %{action: :deploy, phase: :completed, id: id}), do: Admission.mark(ledger, id, :active)
  defp settle(ledger, %{topology_id: id}), do: Admission.uncertain_deployment(ledger, id)

  defp prepare(state, :deploy, %Jido.Topology.Instance{} = topology) do
    with :ok <- Retention.deployment(state, topology.id),
         {:ok, %{placements: selected}} <- plan(state, topology),
         {:ok, topology} <- Jido.Topology.instantiate(topology.definition, id: topology.id, input: topology.input),
         false <- Map.has_key?(state.deployments, topology.id),
         activation = Activation.new(state.ledger.scope, topology.id),
         {:ok, federation} <- Intent.new(topology, selected, activation) do
      {:ok,
       %{
         instance: topology,
         selected: selected,
         initial_selected: selected,
         runner: nil,
         desired: :running,
         phase: :accepted,
         reason: nil,
         activation: activation,
         federation: federation,
         federation_transition: nil,
         recovery: :idle,
         recovery_hosts: %{}
       }}
    else
      true -> {:error, :deployment_exists}
      error -> error
    end
  end

  defp prepare(_, :deploy, _), do: {:error, :invalid_topology}

  defp prepare(state, :stop, id) do
    with {:ok, deployment} <- fetch(state.deployments, id),
         false <-
           deployment.phase == :accepted or Map.get(deployment, :recovery) == :pending or
             Map.get(deployment, :binding_busy, false) do
      {:ok,
       Map.merge(deployment, %{
         desired: :stopped,
         phase: :accepted,
         prior_phase: deployment.phase,
         federation: Intent.detaching(Map.get(deployment, :federation))
       })}
    else
      true -> {:error, :busy}
      error -> error
    end
  end

  defp plan(state, %Jido.Topology.Instance{} = topology) do
    hosts =
      Enum.map(
        Admission.available_hosts(state.ledger),
        &Map.put(&1, :available, &1.available and &1.node in [node() | Node.list()])
      )

    with {:ok, validated} <- Jido.Topology.instantiate(topology.definition, id: topology.id, input: topology.input) do
      case Planner.plan(validated, hosts) do
        {:ok, placements} ->
          federation_plan(state.config, validated, placements)

        {:error, {:no_capacity, key}} = error ->
          explain_blocked(state.ledger, validated, key, error)

        error ->
          error
      end
    end
  end

  defp plan(_, _), do: {:error, :invalid_topology}

  defp federation_plan(config, topology, placements) do
    with {:ok, _} <- Runtime.plan(topology, config.namespace, placements, node(), config.federation),
         do: {:ok, %{placements: placements}}
  end

  defp explain_blocked(ledger, topology, key, error) do
    requirements = topology.definition.metadata |> Map.get("jido.cluster.requirements", %{}) |> Map.get(key, [])
    spec = Map.fetch!(topology.plan.agents, Plan.resolve(topology.plan, key, :agent))

    claims =
      Enum.filter(Admission.claims(ledger), fn claim ->
        host = Map.fetch!(ledger.hosts, claim.host)

        claim.state == :uncertain and host.available and
          Enum.all?(requirements, &(&1 in host.labels)) and Placement.locality(spec, host.node, node()) == :ok
      end)

    if claims == [], do: error, else: {:error, {:resources_uncertain, Enum.map(claims, & &1.id)}}
  end

  defp finish(state, ref, result) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        state

      {id, tasks} ->
        previous = Map.fetch!(state.operations, id)

        state =
          if previous.action in [:acquire_host, :release_host],
            do: HostControl.result(state, previous.host, result),
            else: state

        op = Map.merge(Map.fetch!(state.operations, id), Map.take(result, [:phase, :reason]))
        deployments = finish_deployments(state.deployments, op, result)
        {ready, pending} = Enum.split_with(state.waiters, fn {_, {operation, _, _}} -> operation == id end)

        candidate = %{
          state
          | ledger: settle(state.ledger, op),
            tasks: tasks,
            host_tasks: Map.delete(state.host_tasks, ref),
            operations: Map.put(state.operations, id, op),
            deployments: deployments,
            waiters: Map.new(pending)
        }

        {reply, next} =
          case Store.persist(state, candidate) do
            {:ok, saved} ->
              {{:ok, op}, saved}

            {:error, _reason, failed} ->
              {{:error, failed.store_status},
               %{failed | tasks: tasks, host_tasks: Map.delete(failed.host_tasks, ref), waiters: Map.new(pending)}}
          end

        for {_, {_, from, timer}} <- ready do
          Process.cancel_timer(timer)
          GenServer.reply(from, reply)
        end

        next
    end
  end

  defp finish_deployments(deployments, %{action: action}, _) when action in [:acquire_host, :release_host],
    do: deployments

  defp finish_deployments(deployments, %{action: :drain} = op, result) do
    Enum.reduce(op.steps, deployments, fn {id, step}, deployments ->
      if step.phase == :completed do
        deployments
      else
        Map.update!(deployments, id, &Map.merge(&1, Map.take(result, [:phase, :reason])))
      end
    end)
  end

  defp finish_deployments(deployments, %{action: :stop, phase: :completed} = op, result) do
    Map.update!(deployments, op.topology_id, fn d ->
      d
      |> Map.merge(result)
      |> Map.put(:federation, Intent.stopped(Map.get(d, :federation)))
      |> Map.put(:federation_transition, nil)
    end)
  end

  defp finish_deployments(deployments, op, result),
    do: Map.update!(deployments, op.topology_id, &Map.merge(&1, result))

  defp observation(deployment, status) do
    %{
      id: deployment.instance.id,
      activation: deployment.activation,
      recovery: Map.get(deployment, :recovery, :idle),
      desired: deployment.desired,
      operation_id: deployment.operation,
      binding_intent: Map.get(deployment, :federation),
      binding_transition: Map.get(deployment, :federation_transition),
      binding_repair: if(Map.get(deployment, :binding_busy, false), do: :running, else: :idle),
      agent_readiness: readiness(deployment, status),
      binding_readiness: :ready,
      federation_health: :disabled,
      phase: deployment.phase,
      reason: deployment.reason
    }
  end

  defp readiness(_, status) when status != :ready, do: :uncertain
  defp readiness(%{recovery: :pending}, _), do: :recovering
  defp readiness(%{recovery: :uncertain}, _), do: :uncertain
  defp readiness(%{desired: :stopped, phase: :completed}, _), do: :stopped
  defp readiness(%{desired: :stopped, phase: :accepted}, _), do: :stopping
  defp readiness(%{phase: :completed, runner: runner}, _), do: current_readiness(runner)
  defp readiness(deployment, _), do: deployment.phase

  defp current_readiness(nil), do: :pending

  defp current_readiness(runner) do
    Deployment.status(runner).status
  catch
    :exit, _ -> :uncertain
  end

  defp runtime_recovery?(state) do
    Enum.any?(state.deployments, fn {_, d} ->
      d.desired == :running and current_readiness(d.runner) != :ready
    end)
  end

  defp lookup(state, %Jido.Agent.Ref{namespace: namespace, id: id, partition: nil})
       when namespace == state.config.namespace do
    state.deployments |> find_agent(id) |> resolve_location()
  catch
    :exit, _ -> {:error, :uncertain}
  end

  defp lookup(_, _), do: {:error, :invalid_ref}

  defp find_agent(deployments, id) do
    Enum.find_value(deployments, fn {_, deployment} ->
      agent = find_spec(deployment.instance.plan.agents, id)
      if agent, do: {deployment, agent.local}
    end)
  end

  defp find_spec(agents, id), do: Enum.find_value(agents, fn {_, agent} -> if agent.id == id, do: agent end)

  defp resolve_location(nil), do: {:error, :not_found}
  defp resolve_location({%{recovery: recovery}, _}) when recovery in [:pending, :uncertain], do: {:error, :uncertain}
  defp resolve_location({%{phase: :uncertain}, _}), do: {:error, :uncertain}
  defp resolve_location({%{desired: :stopped, phase: :completed}, _}), do: {:error, :stopped}
  defp resolve_location({%{desired: :stopped}, _}), do: {:error, :stopping}
  defp resolve_location({%{runner: nil}, _}), do: {:error, :pending}

  defp resolve_location({deployment, key}) do
    case Deployment.whereis_agent(deployment.runner, key) do
      nil -> {:error, :pending}
      pid -> {:ok, %{pid: pid, node: node(pid), status: :ready}}
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

  defp finish_recovery(state, reason) do
    next = if reason == :ok, do: state, else: RecoveryState.interrupt(state, reason)
    next = RecoveryState.finish(%{next | recovery_task: nil})

    saved =
      case Store.persist(state, next) do
        {:ok, saved} -> saved
        {:error, _, failed} -> %{failed | recovery_task: nil}
      end

    waiters =
      Enum.reduce(saved.waiters, %{}, fn {ref, {id, from, timer} = waiter}, pending ->
        result = if saved.store_status == :ready, do: fetch(saved.operations, id), else: {:error, saved.store_status}

        case result do
          {:ok, %{phase: :accepted}} ->
            Map.put(pending, ref, waiter)

          _ ->
            Process.cancel_timer(timer)
            GenServer.reply(from, result)
            pending
        end
      end)

    %{saved | waiters: waiters}
  end

  defp start_recovery(state) do
    case Store.recover(state) do
      {:ok, saved} ->
        owner = self()
        ids = for {id, d} <- Enum.sort(saved.deployments), d.recovery == :pending, do: id

        task =
          Task.Supervisor.async_nolink(Instance.name(saved.config.name, Operations), fn ->
            HostWork.recover(owner, :running)
            Recovery.run(saved.config, owner, ids)
            HostWork.recover(owner, :released)
          end)

        {:reply, :ok, %{saved | recovery_task: task}}

      {:error, reason, failed} ->
        {:reply, {:error, reason}, failed}
    end
  end

  defp start_binding_repair(state) do
    ids = for {id, d} <- Enum.sort(state.deployments), d.desired == :running and d.federation != nil, do: id

    if ids == [] do
      {:reply, :ok, state}
    else
      owner = self()

      task =
        Task.Supervisor.async_nolink(Instance.name(state.config.name, Operations), fn ->
          BindingRepair.run(owner, ids)
        end)

      pass = %{pid: task.pid, ref: task.ref, kind: :bindings, ids: ids}
      {:reply, :ok, %{state | recovery_task: pass}}
    end
  end

  defp finish_binding_pass(state, result) do
    deployments =
      Map.new(state.deployments, fn {id, d} ->
        {id, if(Map.get(d, :binding_busy, false), do: finish_binding(d, result), else: d)}
      end)

    next = %{state | deployments: deployments, recovery_task: nil}

    if deployments == state.deployments do
      next
    else
      case Store.persist(state, next) do
        {:ok, saved} -> saved
        {:error, _, failed} -> %{failed | recovery_task: nil}
      end
    end
  end

  defp finish_binding(d, result) do
    reason =
      case result do
        :ok -> nil
        {:error, reason} -> {:binding_repair, reason}
      end

    d |> Map.put(:binding_busy, false) |> Map.put(:reason, reason)
  end
end
