defmodule Jido.Cluster.Deployment.Owner do
  @moduledoc false
  use GenServer
  alias Jido.Cluster.Activation
  alias Jido.Cluster.Deployment.Operation
  alias Jido.Cluster.Federation.Mirror
  alias Jido.Topology.Controller

  @doc "Returns a temporary ownership child specification."
  @spec child_spec({pid(), map()}) :: Supervisor.child_spec()
  def child_spec(args),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}, restart: :temporary, shutdown: 15_000}

  @doc "Starts an ownership process under the cluster ownership supervisor."
  @spec start(pid(), map()) :: {:ok, pid(), pid()} | {:error, term()}
  def start(runner, state) do
    with {:ok, owner} <- DynamicSupervisor.start_child(Jido.Cluster.OwnerSupervisor, {__MODULE__, {runner, state}}),
         do: {:ok, owner, GenServer.call(owner, :controllers)}
  end

  @doc "Starts the linked ownership process and claims its connected global name."
  @spec start_link({pid(), map()}) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc "Starts one bounded operation and returns its result reference."
  @spec run(pid(), map(), map()) :: reference() | {:error, term()}
  def run(owner, state, desired), do: GenServer.call(owner, {:run, state, desired})

  @doc "Starts or resolves the owned Controller using its original accepted definition."
  @spec controller(pid(), Jido.Topology.Instance.t()) :: {:ok, pid()} | {:error, term()}
  def controller(owner, instance), do: GenServer.call(owner, {:controller, instance}, 15_000)

  @doc "Cancels pending work and releases ownership after core cleanup succeeds."
  @spec stop(pid()) :: :ok | {:error, term()}
  def stop(owner), do: GenServer.call(owner, :stop, 15_000)

  @doc "Changes a mirror resource revision only for this owner's current operation task."
  @spec resource(pid(), :close | :prepare, node(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def resource(owner, action, host, channel, revision),
    do: GenServer.call(owner, {:resource, action, host, channel, revision})

  @impl true
  def init({runner, state}) do
    Process.flag(:trap_exit, true)
    key = {__MODULE__, Jido.namespace(state.jido), state.instance.id}
    # Node.connect/1 can precede global's name-table synchronization.
    :ok = :global.sync()

    case :global.register_name(key, self()) do
      :yes ->
        case Activation.claim(get_in(state, [:guard, :activation]), self()) do
          :ok ->
            {:ok, tasks} = Task.Supervisor.start_link()
            {:ok, controllers} = DynamicSupervisor.start_link(strategy: :one_for_one)
            monitor = Process.monitor(runner)
            handler = {__MODULE__, self()}

            :ok =
              :telemetry.attach(
                handler,
                [:jido, :topology, :ownership, :settled],
                &Operation.notify/4,
                {self(), state.instance.id}
              )

            {:ok,
             %{
               runner: runner,
               monitor: monitor,
               key: key,
               jido: state.jido,
               id: state.instance.id,
               activation: get_in(state, [:guard, :activation]),
               tasks: tasks,
               controllers: controllers,
               task: nil,
               controller: nil,
               controller_monitor: nil,
               controller_children: [],
               baseline: nil,
               settlement: :ok,
               cleanup_token: nil,
               handler: handler,
               stopping: false,
               cleaned: false,
               cleanup_hosts: []
             }}

          {:error, reason} ->
            {:stop, reason}
        end

      :no ->
        {:stop, {:deployment_already_running, :global.whereis_name(key)}}
    end
  end

  @impl true
  def handle_call(:controllers, _from, state), do: {:reply, state.controllers, state}

  def handle_call(
        {:resource, action, host, channel, revision},
        {caller, _},
        %{task: %{pid: caller}, stopping: false} = state
      )
      when action in [:close, :prepare] do
    result =
      if action == :close,
        do: Activation.close_resource(state.activation, self(), host, channel, revision),
        else: Activation.prepare_resource(state.activation, self(), host, channel, revision)

    {:reply, result, state}
  end

  def handle_call({:resource, _, _, _, _}, _, state), do: {:reply, {:error, :operation_owner_mismatch}, state}

  def handle_call({:controller, _}, _from, %{stopping: true} = state),
    do: {:reply, {:error, :activation_closed}, state}

  def handle_call({:run, _, _}, _from, %{stopping: true} = state),
    do: {:reply, {:error, :activation_closed}, state}

  def handle_call({:controller, _instance}, _from, %{settlement: settlement} = state)
      when settlement in [:pending, :error],
      do: {:reply, {:error, :controller_cleanup_uncertain}, state}

  def handle_call({:controller, instance}, _from, state) do
    cond do
      state.controller && Process.alive?(state.controller) ->
        {:reply, {:ok, state.controller}, state}

      state.controller && state.settlement != :ok ->
        {:reply, {:error, :controller_cleanup_uncertain}, state}

      true ->
        {result, state} = start_controller(state, state.baseline || instance)
        {:reply, result, state}
    end
  end

  def handle_call({:run, _operation, _desired}, _from, %{task: task} = state) when not is_nil(task),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:run, operation, desired}, _from, state) do
    operation = Map.put(operation, :controller_supervisor, state.controllers)
    task = Task.Supervisor.async_nolink(state.tasks, fn -> run_operation(operation, desired) end)
    hosts = Enum.uniq(state.cleanup_hosts ++ Map.values(desired) ++ guard_hosts(operation))
    {:reply, task.ref, %{state | task: task, cleanup_hosts: hosts}}
  end

  def handle_call(:stop, _from, state) do
    case cleanup(state) do
      :ok -> {:stop, :normal, :ok, %{state | cleaned: true, task: nil}}
      error -> {:reply, error, %{state | task: nil, stopping: true}}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    send(state.runner, {ref, result})

    hosts =
      case result do
        {:ok, _controller, placements} -> Enum.uniq(Map.values(placements))
        _ -> state.cleanup_hosts
      end

    {:noreply, %{state | task: nil, cleanup_hosts: hosts}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    send(state.runner, {ref, {:error, {:operation_uncertain, reason}}})
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    case cleanup(state) do
      :ok -> {:stop, :normal, %{state | cleaned: true, task: nil}}
      _error -> {:noreply, %{state | runner: nil, task: nil, stopping: true}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{controller_monitor: ref} = state) do
    if state.runner, do: send(state.runner, {:controller_down, reason})
    token = make_ref()
    Process.send_after(self(), {:cleanup_timeout, token}, 10_000)
    {:noreply, %{state | settlement: :pending, cleanup_token: token}}
  end

  def handle_info({:cluster_controller_settled, id, status}, %{id: id} = state) do
    if state.controller && not Process.alive?(state.controller) do
      restart_controller(%{state | settlement: if(status == :ok, do: :ok, else: :error)})
    else
      {:noreply, state}
    end
  end

  def handle_info({:cleanup_timeout, token}, %{settlement: :pending, cleanup_token: token} = state) do
    if state.runner, do: send(state.runner, {:controller_restart_failed, :cleanup_uncertain})
    {:noreply, %{state | settlement: :error}}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, {:owned_supervisor_exit, reason}, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    unless state.cleaned, do: cleanup(state)
    :telemetry.detach(state.handler)
    if :global.whereis_name(state.key) == self(), do: :global.unregister_name(state.key)
    :ok
  end

  defp cleanup(state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)

    with :ok <- Activation.close(state.activation, self()),
         :ok <- reachable_cleanup_hosts(state),
         :ok <- Mirror.cleanup(state.jido, state.activation, self()),
         :ok <- stop_core(state),
         :ok <- await_children(state.controller_children),
         :ok <- reachable_cleanup_hosts(state),
         do: Activation.settle(state.activation, self())
  catch
    kind, reason -> {:error, {:cleanup_uncertain, kind, reason}}
  end

  defp run_operation(%{binding_repair: true} = operation, desired),
    do: Operation.repair_bindings(operation, desired)

  defp run_operation(operation, desired), do: Operation.apply_plan(operation, desired)

  defp guard_hosts(%{guard: %{hosts: hosts}}), do: Enum.map(hosts, fn %{server: {_name, host}} -> host end)
  defp guard_hosts(_), do: []

  defp reachable_cleanup_hosts(state) do
    missing = state.cleanup_hosts -- [node() | Node.list()]
    if missing == [], do: :ok, else: {:error, {:cleanup_hosts_unreachable, Enum.sort(missing)}}
  end

  defp stop_core(state) do
    cond do
      state.controller && Process.alive?(state.controller) ->
        Operation.stop_owned_controller(state.controller, state.id, 10_000, state.controllers)

      state.settlement == :ok ->
        :ok

      state.settlement == :error ->
        {:error, :cleanup_failed}

      true ->
        receive do
          {:cluster_controller_settled, id, :ok} when id == state.id -> :ok
          {:cluster_controller_settled, id, _status} when id == state.id -> {:error, :cleanup_failed}
        after
          10_000 -> {:error, :cleanup_uncertain}
        end
    end
  end

  defp start_controller(state, instance) do
    spec =
      Supervisor.child_spec({Controller, jido: state.jido, topology: instance, repair: :manual}, restart: :temporary)

    case DynamicSupervisor.start_child(state.controllers, spec) do
      {:ok, controller} = result ->
        if state.controller_monitor, do: Process.demonitor(state.controller_monitor, [:flush])

        {result,
         %{
           state
           | controller: controller,
             cleanup_hosts: Enum.uniq(state.cleanup_hosts ++ Map.values(Operation.placements(controller, instance))),
             controller_monitor: Process.monitor(controller),
             controller_children: controller_children(controller),
             baseline: instance,
             cleanup_token: nil,
             settlement: :running
         }}

      error ->
        {error, state}
    end
  end

  defp restart_controller(state) do
    if state.runner, do: send(state.runner, {:controller_restart_failed, :cleanup_failed})
    {:noreply, state}
  end

  defp controller_children(controller) do
    for {_, pid, _, _} <- Supervisor.which_children(controller), is_pid(pid), do: pid
  catch
    :exit, _reason -> []
  end

  defp await_children(children) do
    deadline = System.monotonic_time(:millisecond) + 10_000

    Enum.reduce_while(children, :ok, fn child, :ok ->
      ref = Process.monitor(child)
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ^ref, :process, ^child, _reason} -> {:cont, :ok}
      after
        remaining ->
          Process.demonitor(ref, [:flush])
          {:halt, {:error, :controller_shutdown_uncertain}}
      end
    end)
  end
end
