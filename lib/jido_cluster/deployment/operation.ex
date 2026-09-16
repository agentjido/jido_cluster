defmodule Jido.Cluster.Deployment.Operation do
  @moduledoc false
  alias Jido.Cluster.Deployment.{Owner, Planner}
  alias Jido.Cluster.Federation.Runtime
  alias Jido.Cluster.Instance.Hosts
  alias Jido.Topology.Controller

  @doc "Applies a complete selected plan through a manual core Controller."
  @spec apply_plan(map(), map()) :: {:ok, pid(), map()} | {:error, term()}
  def apply_plan(state, desired) do
    with :ok <- Hosts.verify(Map.get(state, :guard)),
         :ok <- compatible(state, Map.values(desired)),
         {:ok, controller} <- controller(state, desired),
         current = placements(controller, state.instance),
         :ok <- reachable(current),
         {:ok, desired} <- selected_plan(state, current, desired),
         :ok <- compatible(state, Map.values(desired)),
         :ok <- await_active_pass(controller, state.timeout),
         :ok <- Runtime.before_move(state, current, desired),
         :ok <- move(controller, current, desired, state.timeout),
         :ok <- Controller.reconcile(controller),
         :ok <- Controller.await_ready(controller, state.timeout),
         accepted = placements(controller, state.instance),
         true <- accepted == desired,
         :ok <- Runtime.setup(state, controller, accepted) do
      {:ok, controller, accepted}
    else
      false -> {:error, :placement_changed}
      error -> error
    end
  rescue
    error -> {:error, {:operation_failed, error}}
  catch
    kind, reason -> {:error, {:operation_uncertain, kind, reason}}
  end

  @doc "Rebuilds mirrors for an existing ready Controller without changing Core placement."
  @spec repair_bindings(map(), map()) :: {:ok, pid(), map()} | {:error, term()}
  def repair_bindings(state, selected) do
    with :ok <- Hosts.verify(state.guard),
         controller when is_pid(controller) <- Controller.whereis(state.jido, state.instance.id),
         %{status: :ready} <- Controller.status(controller),
         true <- placements(controller, state.instance) == selected,
         agents = agent_pids(controller, state.instance),
         true <- Enum.all?(agents, fn {_, pid} -> is_pid(pid) end),
         :ok <- reachable(selected),
         :ok <- Runtime.before_move(state, selected, selected),
         true <- agent_pids(controller, state.instance) == agents,
         :ok <- Runtime.setup(state, controller, selected),
         true <- agent_pids(controller, state.instance) == agents do
      {:ok, controller, selected}
    else
      {:error, _} = error -> error
      _ -> {:error, :binding_target_changed}
    end
  catch
    _, _ -> {:error, :binding_repair_uncertain}
  end

  defp agent_pids(controller, instance),
    do: Map.new(instance.definition.agents, &{&1.key, Controller.whereis_agent(controller, &1.key)})

  defp selected_plan(%{reservation: selected} = state, _current, selected) when is_map(selected) do
    with :ok <- Planner.validate_reservation(state.instance, live_hosts(state), selected), do: {:ok, selected}
  end

  @doc "Stops a core Controller and waits for its public ownership cleanup event."
  @spec stop_controller(atom(), String.t(), pos_integer(), Supervisor.supervisor()) :: :ok | {:error, term()}
  def stop_controller(jido, id, timeout, supervisor) do
    # Wait for any child start already submitted by a cancelled operation.
    _ = DynamicSupervisor.which_children(supervisor)

    case Controller.whereis(jido, id) do
      nil -> :ok
      controller -> settled_stop(controller, id, timeout, supervisor)
    end
  end

  @doc "Stops the known owned Controller even after its core Registry has stopped."
  @spec stop_owned_controller(pid(), String.t(), pos_integer(), Supervisor.supervisor()) :: :ok | {:error, term()}
  def stop_owned_controller(controller, id, timeout, supervisor),
    do: settled_stop(controller, id, timeout, supervisor)

  @doc false
  @spec notify(list(), map(), map(), {pid(), String.t()}) :: term()
  def notify(_event, _measurements, %{topology_id: id, status: status}, {receiver, id}),
    do: send(receiver, {:cluster_controller_settled, id, status})

  def notify(_event, _measurements, _metadata, _config), do: :ok

  @doc "Reads effective root placements through the public core Controller."
  @spec placements(pid(), Jido.Topology.Instance.t()) :: map()
  def placements(controller, instance),
    do: Map.new(instance.definition.agents, &{&1.key, Controller.agent_node(controller, &1.key)})

  defp settled_stop(controller, id, timeout, supervisor) do
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, [:jido, :topology, :ownership, :settled], &__MODULE__.notify/4, {self(), id})

    try do
      :ok = DynamicSupervisor.terminate_child(supervisor, controller)

      receive do
        {:cluster_controller_settled, ^id, :ok} -> :ok
        {:cluster_controller_settled, ^id, _status} -> {:error, :cleanup_failed}
      after
        timeout -> {:error, :cleanup_uncertain}
      end
    after
      :telemetry.detach(handler)
    end
  end

  defp compatible(state, workers) do
    namespace = Jido.namespace(state.jido)

    Enum.reduce_while(Enum.uniq(workers), :ok, fn worker, :ok ->
      if :erpc.call(worker, Jido, :namespace, [state.jido], state.timeout) == namespace,
        do: {:cont, :ok},
        else: {:halt, {:error, {:incompatible_host, worker}}}
    end)
  end

  defp controller(state, desired) do
    initial = get_in(state, [:guard, :initial_selected]) || desired

    with {:ok, instance} <- Planner.instantiate(state.instance, initial),
         do: Owner.controller(state.owner, instance)
  end

  defp reachable(current) do
    missing = current |> Map.values() |> Enum.uniq() |> Enum.reject(&(&1 in [node() | Node.list()])) |> Enum.sort()
    if missing == [], do: :ok, else: {:error, {:source_unreachable, missing}}
  end

  defp live_hosts(state),
    do: Enum.map(state.hosts, &Map.put(&1, :available, &1.available and &1.node in [node() | Node.list()]))

  defp await_active_pass(controller, timeout) do
    case Controller.status(controller) do
      %{active: 0, pending: 0} -> :ok
      _status -> Controller.await_ready(controller, timeout)
    end
  end

  defp move(controller, current, desired, timeout) do
    Enum.reduce_while(Enum.sort(desired), :ok, fn {key, worker}, :ok ->
      result = move_one(controller, key, worker, Map.get(current, key), timeout)
      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp move_one(_controller, _key, worker, worker, _timeout), do: :ok

  defp move_one(controller, key, worker, _old, timeout) do
    with :ok <- Controller.place_agent(controller, key, worker, timeout: timeout),
         do: Controller.await_ready(controller, timeout)
  end
end
