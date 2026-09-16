defmodule Jido.Cluster.Federation.Bridge do
  @moduledoc """
  Explicit local publication with bounded outbound submission.

  Callers reserve a local slot before placing a Signal in this process's mailbox.
  The bridge appends to its local Bus before submitting a bounded export task.
  A successful receipt confirms those two boundaries, not remote consumption.
  A later transport failure leaves local acceptance unchanged and updates status.

  Only `publish/2` creates exports. Ordinary Bus publication and imported Signals
  are never observed for forwarding. One task owns each admitted envelope and
  visits its configured interested hosts in deterministic order. At most the
  outbound slot count of tasks can exist. An idle bridge permits target updates;
  in-flight work must finish before a target can be removed.

  `health` describes the last observed submission results. Live connection and
  Agent binding observations belong to the mirror lifecycle. This module does not
  start Agents or report deployment readiness. Caller memory, Agent mailboxes,
  ordinary Bus publishers, and fixed protocol overhead are outside its byte budget.

  The optional `task_supervisor` is a live local supervisor dedicated to this
  bridge. Its caller owns cleanup. Mirror uses this option to retain task cleanup
  authority after bridge failure. Without this option, the bridge starts and
  owns its task supervisor. Supervisor loss closes the bridge in either mode.
  """
  use GenServer, restart: :temporary

  alias Jido.Cluster.Federation.{Channel, Envelope, Gate, Limits}
  alias Jido.Signal.Bus

  @doc "Starts a bridge for an existing local Bus and validated destination handles."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns a caller handle for direct admission before payload mailbox submission."
  @spec endpoint(pid()) :: map()
  def endpoint(bridge), do: GenServer.call(bridge, :endpoint)

  @doc "Accepts one local publication and bounded export, or reports a pre-append rejection."
  @spec publish(map(), Jido.Signal.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def publish(endpoint, signal, timeout \\ 5000)

  def publish(endpoint, signal, timeout) when timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
    with {:ok, envelope} <- Envelope.new(endpoint.scope, endpoint.generation, signal, endpoint.limits),
         {:ok, _} <- Envelope.validate(envelope, endpoint.scope, endpoint.types, endpoint.limits),
         {:ok, permit} <- Gate.reserve(endpoint.gate, Envelope.bytes(envelope)) do
      GenServer.call(endpoint.pid, {:publish, permit, envelope}, timeout)
    end
  catch
    :exit, _ -> {:error, :publication_uncertain}
  end

  def publish(_, _, _), do: {:error, :invalid_timeout}

  @doc "Reports capacity, submission counts, and last observed transport failures without payloads."
  @spec status(pid(), timeout()) :: map()
  def status(bridge, timeout \\ 5000), do: GenServer.call(bridge, :status, timeout)

  @doc "Returns the task supervisor whose exit confirms export task cleanup."
  @spec work_owner(pid()) :: pid()
  def work_owner(bridge), do: GenServer.call(bridge, :work_owner)

  @doc "Changes interested destinations only while no admitted publication remains in flight."
  @spec set_targets(pid(), [map()]) :: :ok | {:error, term()}
  def set_targets(bridge, targets), do: GenServer.call(bridge, {:targets, targets})

  @impl true
  def init(opts) do
    case config(opts) do
      {:ok, config} ->
        Process.flag(:trap_exit, true)
        {:ok, tasks, owned} = task_supervisor(config.task_supervisor)

        {:ok,
         Map.merge(config, %{
           generation: Jido.generate_id(),
           gate: Gate.new(config.limits, :outbound),
           task_supervisor: tasks,
           owns_tasks: owned,
           tasks_monitor: Process.monitor(tasks),
           tasks: %{},
           bus_monitor: Process.monitor(config.bus),
           accepted: 0,
           appended: 0,
           duplicates: 0,
           rejected: 0,
           uncertain: 0,
           submission_uncertain: false,
           failures: %{}
         })}

      error ->
        {:stop, elem(error, 1)}
    end
  end

  @impl true
  def handle_call(:endpoint, _, state) do
    endpoint = state |> Map.take([:scope, :types, :limits, :generation, :gate]) |> Map.put(:pid, self())
    {:reply, endpoint, state}
  end

  def handle_call(:status, _, state), do: {:reply, observation(state), state}

  def handle_call(:work_owner, _, state), do: {:reply, state.task_supervisor, state}

  def handle_call({:targets, targets}, _, state) do
    with :ok <- targets_valid(targets, state.limits),
         %{used_slots: 0} <- Gate.status(state.gate) do
      {:reply, :ok, %{state | targets: Enum.sort_by(targets, & &1.host), failures: %{}}}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :busy}, state}
    end
  end

  def handle_call({:publish, permit, envelope}, _, state) do
    case Bus.publish(state.bus, [envelope.signal]) do
      {:ok, [_]} ->
        submit(permit, envelope, %{state | accepted: state.accepted + 1})

      {:error, reason} ->
        :ok = Gate.release(state.gate, permit)
        {:reply, {:error, {:local_append, reason}}, state}
    end
  end

  @impl true
  def handle_info({ref, results}, state) when is_reference(ref) do
    case Map.fetch(state.tasks, ref) do
      :error -> {:noreply, state}
      {:ok, task} -> {:noreply, put_in(state, [:tasks, ref], Map.put(task, :results, results))}
    end
  end

  def handle_info({:DOWN, monitor, :process, _, reason}, %{bus_monitor: monitor} = state),
    do: {:stop, {:bus_down, reason}, state}

  def handle_info({:DOWN, monitor, :process, _, reason}, %{tasks_monitor: monitor} = state),
    do: {:stop, {:task_supervisor_down, reason}, state}

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {task, tasks} ->
        :ok = Gate.release(state.gate, task.permit)

        results =
          Map.get_lazy(task, :results, fn ->
            Enum.map(task.hosts, &%{host: &1, phase: :uncertain, reason: :task_exit})
          end)

        {:noreply, record(%{state | tasks: tasks}, results)}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{task_supervisor: pid} = state),
    do: {:stop, {:task_supervisor_down, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.owns_tasks and Process.alive?(state.task_supervisor),
      do: Supervisor.stop(state.task_supervisor, :shutdown, :infinity)

    :ok
  end

  defp submit(permit, envelope, state) do
    receipt = %{
      scope: state.scope,
      signal_id: envelope.signal.id,
      export_id: envelope.export_id,
      local: :accepted,
      outbound: :submitted,
      targets: Enum.map(state.targets, & &1.host)
    }

    if state.targets == [] do
      :ok = Gate.release(state.gate, permit)
      {:reply, {:ok, receipt}, state}
    else
      targets = state.targets
      task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> Enum.map(targets, &transmit(&1, envelope)) end)
      work = %{permit: permit, hosts: receipt.targets}
      {:reply, {:ok, receipt}, put_in(state, [:tasks, task.ref], work)}
    end
  catch
    :exit, _ ->
      # A timed-out start can still have created a task. Keep its permit charged
      # until generation closure rather than admit work over an unknown payload.
      {:reply, {:error, {:publication_uncertain, envelope.export_id}},
       %{state | uncertain: state.uncertain + 1, submission_uncertain: true}}
  end

  defp transmit(target, envelope) do
    result = safely_transmit(target, envelope)
    {phase, reason} = outcome(result)
    {namespace, topology, channel} = envelope.scope

    :telemetry.execute([:jido, :cluster, :federation, :export], %{count: 1}, %{
      namespace: namespace,
      topology_id: topology,
      channel: channel,
      host: target.host,
      generation: envelope.generation,
      export_id: envelope.export_id,
      phase: phase
    })

    %{host: target.host, phase: phase, reason: reason}
  end

  defp safely_transmit(target, envelope) do
    target.transport.transmit(target.handle, envelope)
  rescue
    _ -> {:error, :transport_exception}
  catch
    _, _ -> {:error, :transport_exception}
  end

  defp outcome({:ok, :appended}), do: {:appended, nil}
  defp outcome({:ok, :duplicate}), do: {:duplicates, nil}

  defp outcome({:error, reason}) when reason in [:capacity, :closed, :noconnect, :nosuspend, :dedup_capacity],
    do: {:rejected, reason}

  defp outcome({:error, {:local_append, _}}), do: {:rejected, :local_append_rejected}
  defp outcome({:error, _}), do: {:uncertain, :transport_uncertain}
  defp outcome(_), do: {:uncertain, :invalid_transport_result}

  defp record(state, results) do
    Enum.reduce(results, state, fn result, state ->
      state = Map.update!(state, result.phase, &(&1 + 1))

      failures =
        if result.reason,
          do: Map.put(state.failures, result.host, result.reason),
          else: Map.delete(state.failures, result.host)

      %{state | failures: failures}
    end)
  end

  defp observation(state) do
    state
    |> Map.take([
      :scope,
      :generation,
      :accepted,
      :appended,
      :duplicates,
      :rejected,
      :uncertain,
      :failures,
      :submission_uncertain
    ])
    |> Map.merge(%{
      in_flight: map_size(state.tasks),
      capacity: Gate.status(state.gate),
      targets: Enum.map(state.targets, & &1.host),
      health: if(map_size(state.failures) == 0 and not state.submission_uncertain, do: :healthy, else: :degraded)
    })
  end

  defp config(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) == map_size(Map.new(opts)),
      do: validate_config(opts |> Map.new() |> Map.put_new(:task_supervisor, nil)),
      else: {:error, :invalid_bridge}
  end

  defp config(_), do: {:error, :invalid_bridge}

  defp validate_config(%{bus: bus, scope: scope, types: types, limits: %Limits{} = limits, targets: targets} = config)
       when map_size(config) == 6 and is_pid(bus) and node(bus) == node() do
    with true <- Process.alive?(bus),
         true <- valid_task_supervisor?(config.task_supervisor),
         :ok <- Channel.validate(scope, types, limits),
         :ok <- targets_valid(targets, limits) do
      {:ok, %{config | targets: Enum.sort_by(targets, & &1.host)}}
    else
      _ -> {:error, :invalid_bridge}
    end
  end

  defp validate_config(_), do: {:error, :invalid_bridge}

  defp valid_task_supervisor?(nil), do: true
  defp valid_task_supervisor?(pid), do: is_pid(pid) and node(pid) == node() and Process.alive?(pid)

  defp task_supervisor(nil) do
    with {:ok, pid} <- Task.Supervisor.start_link(), do: {:ok, pid, true}
  end

  defp task_supervisor(pid), do: {:ok, pid, false}

  defp targets_valid(targets, limits) when is_list(targets) do
    if length(targets) < limits.max_hosts and Enum.all?(targets, &target_valid?/1) and
         length(targets) == length(Enum.uniq_by(targets, & &1.host)), do: :ok, else: {:error, :invalid_targets}
  end

  defp targets_valid(_, _), do: {:error, :invalid_targets}

  defp target_valid?(%{host: host, transport: module, handle: _} = target) when map_size(target) == 3 do
    is_atom(host) and host not in [nil, true, false, node()] and is_atom(module) and
      Code.ensure_loaded?(module) and function_exported?(module, :transmit, 2)
  end

  defp target_valid?(_), do: false

  @impl true
  def format_status(status) do
    status
    |> Map.put(
      :state,
      Map.take(status.state, [:scope, :generation, :accepted, :appended, :duplicates, :rejected, :uncertain])
    )
    |> Map.put(:message, :payload_redacted)
    |> Map.put(:log, [])
  end
end
