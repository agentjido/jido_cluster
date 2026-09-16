defmodule Jido.Cluster.Deployment do
  @moduledoc false
  use GenServer
  alias Jido.Cluster.Deployment.{Operation, Owner, Planner}
  alias Jido.Cluster.Federation.Limits
  alias Jido.Cluster.Instance.Hosts
  alias Jido.Topology.Controller

  @doc "Returns a temporary child specification scoped to the Topology ID."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.fetch!(opts, :topology).id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 15_000
    }

  @doc "Starts the placement coordinator; readiness is reported through status."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         {:ok, state} <- config(opts) do
      name = {:via, Registry, {Jido.registry_name(state.jido), {:cluster_deployment, state.instance.id}}}
      GenServer.start_link(__MODULE__, state, name: name)
    else
      false -> {:error, :invalid_deployment_options}
      error -> error
    end
  end

  @doc "Finds the registered deployment process so recovery can await its exit."
  @spec whereis(atom(), String.t()) :: pid() | nil
  def whereis(jido, id) do
    case Registry.lookup(Jido.registry_name(jido), {:cluster_deployment, id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Reports selected and desired placement, slot usage, drain completion, and errors."
  @spec status(GenServer.server()) :: map()
  def status(runner), do: GenServer.call(runner, :status)

  @doc "Resolves a root singleton through the public core Controller."
  @spec whereis_agent(GenServer.server(), atom() | String.t()) :: pid() | nil
  def whereis_agent(runner, key), do: GenServer.call(runner, {:agent, key})

  @doc "Applies an exact replacement reservation confirmed by the same scope authority."
  @spec apply_reservation(GenServer.server(), map(), map()) :: :ok | {:error, term()}
  def apply_reservation(runner, placements, guard),
    do: GenServer.call(runner, {:reservation, placements, guard})

  @doc "Repairs declared mirrors at the same placement under the existing scope authority."
  @spec repair_bindings(GenServer.server(), map(), map()) :: :ok | {:error, term()}
  def repair_bindings(runner, placements, guard),
    do: GenServer.call(runner, {:repair_bindings, placements, guard})

  @doc "Stops owned core resources and waits for cleanup; persistence records remain."
  @spec stop(GenServer.server()) :: :ok | {:error, term()}
  def stop(runner), do: GenServer.call(runner, :stop, 15_000)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)

    case Owner.start(self(), state) do
      {:ok, owner, controllers} ->
        state =
          Map.merge(state, %{owner: owner, owner_monitor: Process.monitor(owner), controller_supervisor: controllers})

        {:ok, state, {:continue, :schedule}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:schedule, state), do: {:noreply, schedule(state)}

  @impl true
  def handle_call(:status, _from, state) do
    status = Map.take(state, [:status, :placements, :desired, :draining, :drained, :error, :attempts, :repairs])
    reservations = Map.to_list(state.placements) ++ Map.to_list(state.desired)
    reservations = reservations |> Enum.uniq() |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()
    {:reply, status |> Map.put(:reservations, reservations) |> Map.put(:binding_repair, state.binding_repair), state}
  end

  def handle_call({:agent, _key}, _from, %{controller: nil} = state), do: {:reply, nil, state}

  def handle_call({:agent, key}, _from, state) do
    controller = Controller.whereis(state.jido, state.instance.id)
    agent = if controller, do: Controller.whereis_agent(controller, key)
    {:reply, agent, %{state | controller: controller}}
  catch
    _kind, _reason -> {:reply, nil, state}
  end

  def handle_call(:stop, _from, state) do
    case cleanup(state) do
      :ok -> {:stop, :normal, :ok, %{state | cleaned: true}}
      error -> {:reply, error, %{state | status: :uncertain, error: error, task: nil}}
    end
  end

  def handle_call(_request, _from, %{task: task} = state) when not is_nil(task),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:reservation, placements, guard}, _from, state) do
    with true <- is_map(state.guard) and state.guard.owner == guard.owner and state.guard.scope == guard.scope,
         true <- Map.get(state.guard, :activation) == Map.get(guard, :activation),
         :ok <- reachable(state),
         :ok <- Planner.validate_reservation(state.instance, live_hosts(state), placements) do
      {:reply, :ok, launch(%{state | reservation: placements, guard: Map.merge(state.guard, guard)}, placements)}
    else
      false -> {:reply, {:error, :invalid_reservation_owner}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:repair_bindings, selected, guard}, _from, state) do
    with true <- is_map(state.guard) and state.guard.owner == guard.owner and state.guard.scope == guard.scope,
         true <- Map.get(state.guard, :activation) == Map.get(guard, :activation),
         true <- state.status == :ready and state.placements == selected,
         :ok <- Hosts.verify(guard) do
      launch_binding_repair(%{state | guard: Map.merge(state.guard, guard)}, selected)
    else
      false -> {:reply, {:error, :binding_target_changed}, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: %{ref: ref, kind: :bindings}} = state),
    do: {:noreply, finish_binding_repair(state, result)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref, kind: :bindings}} = state),
    do: {:noreply, finish_binding_repair(state, {:error, {:binding_repair_exit, reason}})}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    {:noreply, state |> Map.put(:task, nil) |> finish(result) |> poll_later()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state),
    do: {:noreply, state |> Map.put(:task, nil) |> finish({:error, {:operation_uncertain, reason}}) |> poll_later()}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{owner_monitor: ref} = state),
    do: {:stop, {:owner_down, reason}, state}

  def handle_info({:controller_down, _reason}, %{task: nil, status: :ready} = state),
    do: {:noreply, poll_later(%{state | status: :recovering, controller: nil})}

  def handle_info({:controller_down, _reason}, %{task: nil, status: :recovering} = state),
    do: {:noreply, state}

  def handle_info({:controller_down, reason}, %{task: nil} = state),
    do: {:noreply, poll_later(%{state | status: :uncertain, controller: nil, error: {:controller_down, reason}})}

  def handle_info({:controller_restart_failed, reason}, state),
    do: {:noreply, poll_later(%{state | status: :uncertain, error: {:controller_restart_failed, reason}})}

  def handle_info({:poll, token}, %{task: nil, poll_token: token} = state), do: {:noreply, check(state)}
  def handle_info({:poll, _token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{cleaned: true}), do: :ok
  def terminate(_reason, state), do: cleanup(state)

  defp cleanup(state) do
    if Process.alive?(state.owner),
      do: Owner.stop(state.owner),
      else: Operation.stop_controller(state.jido, state.instance.id, 10_000, state.controller_supervisor)
  catch
    kind, reason -> {:error, {:cleanup_uncertain, kind, reason}}
  end

  defp config(opts) do
    jido = Keyword.get(opts, :jido)
    instance = Keyword.get(opts, :topology)
    hosts = Keyword.get(opts, :hosts)
    poll = Keyword.get(opts, :poll_interval, 250)
    timeout = Keyword.get(opts, :timeout, 5_000)
    valid = match?(%Jido.Topology.Instance{}, instance) and is_atom(jido) and jido not in [nil, true, false]
    limits = Enum.all?([poll, timeout], &(is_integer(&1) and &1 > 0))

    known =
      Keyword.keys(opts) -- [:jido, :topology, :hosts, :poll_interval, :timeout, :reservation, :guard, :federation] ==
        []

    with true <- valid and limits and known,
         :ok <- deployment_authority(Keyword.get(opts, :guard), Keyword.get(opts, :reservation)),
         :ok <- Planner.validate_hosts(hosts),
         {:ok, instance} <- Jido.Topology.instantiate(instance.definition, id: instance.id, input: instance.input),
         {:ok, federation} <- Limits.new(Keyword.get(opts, :federation, [])),
         :ok <- Planner.validate_reservation(instance, hosts, Keyword.get(opts, :reservation)),
         :ok <- instance_started(jido),
         nil <- Controller.whereis(jido, instance.id) do
      {:ok,
       %{
         jido: jido,
         instance: instance,
         reservation: Keyword.get(opts, :reservation),
         guard: Keyword.get(opts, :guard),
         federation: federation,
         hosts: hosts,
         poll_interval: poll,
         timeout: timeout,
         cleaned: false,
         controller: nil,
         binding_repair: nil,
         task: nil,
         poll_timer: nil,
         poll_token: nil,
         placements: %{},
         desired: %{},
         draining: [],
         drained: [],
         status: :starting,
         error: nil,
         attempts: 0,
         repairs: 0
       }}
    else
      false -> {:error, :invalid_deployment_options}
      pid when is_pid(pid) -> {:error, :controller_already_running}
      error -> error
    end
  end

  defp instance_started(jido) do
    if Process.whereis(Jido.registry_name(jido)), do: :ok, else: {:error, :jido_not_started}
  end

  defp deployment_authority(%{owner: owner, scope: scope, activation: activation}, selected)
       when is_pid(owner) and is_tuple(scope) and is_map(activation) and is_map(selected), do: :ok

  defp deployment_authority(_, _), do: {:error, :deployment_authority_required}

  defp schedule(state) do
    state = refresh(state)

    with :ok <- reachable(state),
         {:ok, desired} <- selected_plan(state) do
      launch(state, desired)
    else
      {:error, {:source_unreachable, _} = reason} -> poll_later(%{state | status: :uncertain, error: reason})
      {:error, reason} -> poll_later(%{state | status: :blocked, error: reason, desired: %{}})
    end
  end

  defp selected_plan(state) do
    with :ok <- Planner.validate_reservation(state.instance, live_hosts(state), state.reservation),
         do: {:ok, state.reservation}
  end

  defp launch(state, desired) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)

    state = %{state | poll_timer: nil, poll_token: nil}

    case Owner.run(state.owner, state, desired) do
      ref when is_reference(ref) ->
        %{
          state
          | task: %{ref: ref},
            desired: desired,
            status: :placing,
            error: nil,
            attempts: state.attempts + 1
        }

      {:error, reason} ->
        poll_later(%{state | task: nil, status: :uncertain, error: reason})
    end
  end

  defp launch_binding_repair(state, selected) do
    case Owner.run(state.owner, Map.put(state, :binding_repair, true), selected) do
      ref when is_reference(ref) ->
        repair = %{phase: :running, reason: nil, revision: state.guard.binding_revision}
        {:reply, :ok, %{state | task: %{ref: ref, kind: :bindings}, binding_repair: repair}}

      error ->
        {:reply, error, state}
    end
  end

  defp finish_binding_repair(state, result) do
    {phase, reason} =
      case result do
        {:ok, _, _} -> {:completed, nil}
        {:error, reason} -> {:uncertain, reason}
      end

    repair = %{state.binding_repair | phase: phase, reason: reason}
    poll_later(%{state | task: nil, binding_repair: repair})
  end

  defp finish(state, {:ok, controller, placements}),
    do: %{
      state
      | controller: controller,
        placements: placements,
        desired: placements,
        status: :ready,
        error: nil,
        attempts: 0,
        drained: state.draining
    }

  defp finish(state, {:error, {:incompatible_host, _} = reason}),
    do: %{state | status: :blocked, error: reason, desired: %{}}

  defp finish(state, {:error, reason}) do
    state = refresh(state)
    %{state | status: :uncertain, error: reason}
  end

  defp check(%{status: :ready} = state) do
    state = refresh(state)

    with controller when not is_nil(controller) <- state.controller,
         :ok <- reachable(state),
         :ok <- Hosts.verify(state.guard),
         %{status: :ready} <- Controller.status(controller) do
      poll_later(state)
    else
      nil -> poll_later(%{state | status: :recovering})
      _ -> schedule(%{state | repairs: state.repairs + 1})
    end
  catch
    _kind, _reason -> poll_later(%{state | status: :recovering})
  end

  defp check(%{status: :recovering} = state) do
    state = refresh(state)

    if state.controller do
      case Controller.status(state.controller) do
        %{status: :ready} ->
          finish_recovery(state)

        %{status: :degraded, errors: errors} ->
          poll_later(%{state | status: :uncertain, error: errors})

        _status ->
          poll_later(state)
      end
    else
      poll_later(state)
    end
  catch
    _kind, _reason -> poll_later(state)
  end

  defp check(state), do: poll_later(state)

  defp finish_recovery(state) do
    with :ok <- reachable(state),
         :ok <- Hosts.verify(state.guard),
         {:ok, desired} <- selected_plan(state),
         true <- desired == state.placements do
      poll_later(finish(state, {:ok, state.controller, state.placements}))
    else
      {:error, reason} -> poll_later(%{state | status: :uncertain, error: reason})
      false -> poll_later(%{state | status: :uncertain, error: :placement_changed})
    end
  end

  defp refresh(state) do
    case Controller.whereis(state.jido, state.instance.id) do
      nil -> %{state | controller: nil}
      controller -> %{state | controller: controller, placements: Operation.placements(controller, state.instance)}
    end
  catch
    _kind, _reason -> %{state | controller: nil}
  end

  defp reachable(state) do
    missing = state.placements |> Map.values() |> Enum.uniq() |> Enum.reject(&(&1 in connected())) |> Enum.sort()
    if missing == [], do: :ok, else: {:error, {:source_unreachable, missing}}
  end

  defp live_hosts(state), do: Enum.map(state.hosts, &Map.put(&1, :available, &1.available and &1.node in connected()))
  defp connected, do: [node() | Node.list()]

  defp poll_later(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    token = make_ref()
    timer = Process.send_after(self(), {:poll, token}, state.poll_interval)
    %{state | poll_timer: timer, poll_token: token}
  end
end
