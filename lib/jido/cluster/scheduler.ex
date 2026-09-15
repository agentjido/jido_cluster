defmodule Jido.Cluster.Scheduler do
  @moduledoc """
  Maintains root singleton Topology placement on configured connected BEAM hosts.

  Label requirements come from `Jido.Cluster.Topology.Extension`. Each host has
  a slot budget scoped to this Scheduler. Complete admission precedes startup.
  Core owns activation, checkpoint restore, and cooperative moves. Its Controller
  uses manual repair; this process serializes bounded repair and drain operations.

  Host inventory is application configuration, filtered by the current connected
  view. A lost source produces `:uncertain`; spare capacity is not permission to
  replace an unreachable writer. There is no durable authority, global capacity
  reservation, automatic rebalance, or operation-owner restart guarantee.

  Start after the named Jido instance. `:hosts` requires node, labels, capacity,
  and available fields. `:poll_interval` defaults to 250 ms, `:timeout` to 5000 ms,
  Each request or detected worker exit runs one bounded repair operation. An
  uncertain result requires an explicit retry; there is no automatic retry loop.
  """
  use GenServer
  alias Jido.Cluster.Scheduler.{Operation, Planner}
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
      name = {:via, Registry, {Jido.registry_name(state.jido), {:cluster_scheduler, state.instance.id}}}
      GenServer.start_link(__MODULE__, state, name: name)
    else
      false -> {:error, :invalid_scheduler_options}
      error -> error
    end
  end

  @doc "Reports selected and desired placement, slot usage, drain completion, and errors."
  @spec status(GenServer.server()) :: map()
  def status(scheduler), do: GenServer.call(scheduler, :status)

  @doc "Resolves a root singleton through the public core Controller."
  @spec whereis_agent(GenServer.server(), atom() | String.t()) :: pid() | nil
  def whereis_agent(scheduler, key), do: GenServer.call(scheduler, {:agent, key})

  @doc "Updates configured hosts and requests complete admission or reconciliation."
  @spec update_hosts(GenServer.server(), [Planner.host()]) :: :ok | {:error, term()}
  def update_hosts(scheduler, hosts), do: GenServer.call(scheduler, {:hosts, hosts})

  @doc "Requests a cooperative drain after proving sufficient target capacity."
  @spec drain(GenServer.server(), node()) :: :ok | {:error, term()}
  def drain(scheduler, worker), do: GenServer.call(scheduler, {:drain, worker})

  @doc "Explicitly retries bounded placement or repair without replaying Signals."
  @spec reconcile(GenServer.server()) :: :ok | {:error, :busy}
  def reconcile(scheduler), do: GenServer.call(scheduler, :reconcile)

  @doc "Stops owned core resources and waits for cleanup; persistence records remain."
  @spec stop(GenServer.server()) :: :ok | {:error, term()}
  def stop(scheduler), do: GenServer.call(scheduler, :stop, 15_000)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state), do: {:noreply, schedule(state)}

  @impl true
  def handle_call(:status, _from, state) do
    status = Map.take(state, [:status, :placements, :desired, :draining, :drained, :error, :attempts, :repairs])
    reservations = Map.to_list(state.placements) ++ Map.to_list(state.desired)
    reservations = reservations |> Enum.uniq() |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()
    {:reply, Map.put(status, :reservations, reservations), state}
  end

  def handle_call({:agent, _key}, _from, %{controller: nil} = state), do: {:reply, nil, state}

  def handle_call({:agent, key}, _from, state) do
    {:reply, Controller.whereis_agent(state.controller, key), state}
  catch
    kind, reason -> {:reply, nil, %{state | status: :uncertain, error: {:controller_unavailable, kind, reason}}}
  end

  def handle_call(:stop, _from, state) do
    result = cleanup(state)
    {:stop, :normal, result, %{state | cleaned: true}}
  end

  def handle_call(_request, _from, %{task: task} = state) when not is_nil(task),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:hosts, hosts}, _from, state) do
    case Planner.validate_hosts(hosts) do
      :ok -> {:reply, :ok, schedule(%{state | hosts: hosts, attempts: 0})}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:drain, worker}, _from, state) do
    draining = Enum.uniq([worker | state.draining]) |> Enum.sort()

    with true <- Enum.any?(state.hosts, &(&1.node == worker)),
         :ok <- reachable(state),
         {:ok, desired} <- Planner.plan(state.instance, live_hosts(state), draining, state.placements) do
      {:reply, :ok, launch(%{state | draining: draining, attempts: 0}, desired)}
    else
      false -> {:reply, {:error, :unknown_host}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:reconcile, _from, state), do: {:reply, :ok, schedule(%{state | attempts: 0})}

  @impl true
  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> Map.put(:task, nil) |> finish(result) |> poll_later()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state),
    do: {:noreply, state |> Map.put(:task, nil) |> finish({:error, {:operation_uncertain, reason}}) |> poll_later()}

  def handle_info({:poll, token}, %{task: nil, poll_token: token} = state), do: {:noreply, check(state)}
  def handle_info({:poll, _token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{cleaned: true}), do: :ok
  def terminate(_reason, state), do: cleanup(state)

  defp cleanup(state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    Operation.stop_controller(state.jido, state.instance.id, 10_000)
  end

  defp config(opts) do
    jido = Keyword.get(opts, :jido)
    instance = Keyword.get(opts, :topology)
    hosts = Keyword.get(opts, :hosts)
    poll = Keyword.get(opts, :poll_interval, 250)
    timeout = Keyword.get(opts, :timeout, 5_000)
    valid = match?(%Jido.Topology.Instance{}, instance) and is_atom(jido) and jido not in [nil, true, false]
    limits = Enum.all?([poll, timeout], &(is_integer(&1) and &1 > 0))
    known = Keyword.keys(opts) -- [:jido, :topology, :hosts, :poll_interval, :timeout] == []

    with true <- valid and limits and known,
         :ok <- Planner.validate_hosts(hosts),
         {:ok, instance} <- Jido.Topology.instantiate(instance.definition, id: instance.id, input: instance.input),
         :ok <- instance_started(jido),
         nil <- Controller.whereis(jido, instance.id) do
      {:ok,
       %{
         jido: jido,
         instance: instance,
         hosts: hosts,
         poll_interval: poll,
         timeout: timeout,
         cleaned: false,
         controller: nil,
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
      false -> {:error, :invalid_scheduler_options}
      pid when is_pid(pid) -> {:error, :controller_already_running}
      error -> error
    end
  end

  defp instance_started(jido) do
    if Process.whereis(Jido.registry_name(jido)), do: :ok, else: {:error, :jido_not_started}
  end

  defp schedule(state) do
    with :ok <- reachable(state),
         {:ok, desired} <- Planner.plan(state.instance, live_hosts(state), state.draining, state.placements) do
      launch(state, desired)
    else
      {:error, {:source_unreachable, _} = reason} -> poll_later(%{state | status: :uncertain, error: reason})
      {:error, reason} -> poll_later(%{state | status: :blocked, error: reason, desired: %{}})
    end
  end

  defp launch(state, desired) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)

    task =
      Task.Supervisor.async_nolink(Jido.Cluster.OperationSupervisor, fn -> Operation.apply_plan(state, desired) end)

    %{
      state
      | task: task,
        desired: desired,
        status: :placing,
        error: nil,
        attempts: state.attempts + 1,
        poll_timer: nil,
        poll_token: nil
    }
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
    controller = Controller.whereis(state.jido, state.instance.id)
    %{state | controller: controller, status: :uncertain, error: reason}
  end

  defp check(%{status: :ready} = state) do
    with :ok <- reachable(state),
         %{status: :ready} <- Controller.status(state.controller) do
      poll_later(state)
    else
      _ -> schedule(%{state | repairs: state.repairs + 1})
    end
  catch
    kind, reason -> poll_later(%{state | status: :uncertain, error: {:controller_unavailable, kind, reason}})
  end

  defp check(state), do: poll_later(state)

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
