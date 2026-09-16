defmodule JidoCluster.Test.HostProvider do
  @moduledoc false
  use GenServer
  @behaviour Jido.Cluster.HostProvider
  alias Jido.Cluster.HostProvider.{Resource, Step}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)
  def mode(server, mode), do: GenServer.call(server, {:mode, mode})
  def resources(server), do: GenServer.call(server, :resources)
  def calls(server), do: GenServer.call(server, :calls)
  def complete_acquire(server, step), do: GenServer.call(server, {:complete_acquire, step})
  def replace(server, resource), do: GenServer.call(server, {:replace, resource})

  @impl GenServer
  def init(_), do: {:ok, %{resources: %{}, pending: %{}, closed: MapSet.new(), mode: :normal, calls: []}}

  @impl Jido.Cluster.HostProvider
  def validate_options(opts), do: if(is_pid(opts[:server]), do: :ok, else: {:error, :invalid_server})
  @impl Jido.Cluster.HostProvider
  def acquire(step, opts), do: GenServer.call(opts[:server], {:acquire, step, opts[:host_runtime]})
  @impl Jido.Cluster.HostProvider
  def inspect(step, opts), do: GenServer.call(opts[:server], {:inspect, step, opts[:borrowed_id]})
  @impl Jido.Cluster.HostProvider
  def release(resource, opts), do: GenServer.call(opts[:server], {:release, resource})
  @impl Jido.Cluster.HostProvider
  def discover(scope, limit, opts), do: GenServer.call(opts[:server], {:discover, scope, limit})

  @impl GenServer
  def handle_call({:mode, mode}, _, state), do: {:reply, :ok, %{state | mode: mode}}
  def handle_call(:resources, _, state), do: {:reply, Map.values(state.resources), state}
  def handle_call(:calls, _, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:replace, previous}, _, state) do
    key = key(previous.step)

    if Map.get(state.resources, key) == previous do
      current = resource(previous.step)
      {:reply, {:ok, current}, %{state | resources: Map.put(state.resources, key, current)}}
    else
      {:reply, {:error, :resource_changed}, state}
    end
  end

  def handle_call({:acquire, step, runtime}, _, state) do
    key = key(step)
    state = %{state | calls: [{:acquire, step} | state.calls]}

    cond do
      MapSet.member?(state.closed, key) ->
        {:reply, {:error, {:rejected, :step_closed}}, state}

      Map.has_key?(state.pending, key) ->
        {:reply, {:error, {:indeterminate, :timeout}}, state}

      state.mode == :reject_acquire ->
        {:reply, {:error, {:rejected, :capacity}}, %{state | mode: :normal}}

      state.mode == :delay_acquire ->
        pending = Map.put(state.pending, key, {runtime})
        {:reply, {:error, {:indeterminate, :timeout}}, %{state | pending: pending, mode: :normal}}

      true ->
        resource = Map.get_lazy(state.resources, key, fn -> resource(step) end)
        boot = if Map.has_key?(state.resources, key), do: :ok, else: boot(runtime, step)
        reply = acquisition_reply(boot, state.mode, resource)
        {:reply, reply, %{state | resources: Map.put(state.resources, key, resource), mode: :normal}}
    end
  end

  def handle_call({:complete_acquire, step}, _, state) do
    key = key(step)

    case Map.pop(state.pending, key) do
      {nil, _} ->
        {:reply, {:error, :no_pending_acquire}, state}

      {{runtime}, pending} ->
        resource = resource(step)
        reply = acquisition_reply(boot(runtime, step), :normal, resource)
        {:reply, reply, %{state | pending: pending, resources: Map.put(state.resources, key, resource)}}
    end
  end

  def handle_call({:inspect, step, borrowed_id}, _, state) do
    reply =
      if state.mode == :inspect_unavailable,
        do: {:error, :unavailable},
        else: {:ok, observation(state.resources, step, borrowed_id)}

    mode = if state.mode == :inspect_unavailable, do: :normal, else: state.mode
    {:reply, reply, %{state | mode: mode, calls: [{:inspect, step} | state.calls]}}
  end

  def handle_call({:release, resource}, _, state) do
    state = %{state | calls: [{:release, resource} | state.calls]}

    case Map.get(state.resources, key(resource.step)) do
      nil -> {:reply, :ok, state}
      current -> release_current(resource, current, state)
    end
  end

  def handle_call({:discover, {namespace, scope}, limit}, _, state) do
    resources =
      state.resources
      |> Map.values()
      |> Enum.filter(&(&1.step.namespace == namespace and &1.step.scope == scope))
      |> Enum.sort_by(& &1.step.id)

    reply = if length(resources) <= limit, do: {:ok, resources}, else: {:error, :discovery_limit}
    {:reply, reply, state}
  end

  defp release_current(resource, current, state) do
    cond do
      not Resource.same?(resource, current) ->
        {:reply, {:error, {:rejected, :stale_resource}}, state}

      state.mode == :reject_release ->
        {:reply, {:error, {:rejected, :busy}}, %{state | mode: :normal}}

      true ->
        reply =
          if state.mode in [:lose_release_reply, :lose_release_and_inspection],
            do: {:error, {:indeterminate, :timeout}},
            else: :ok

        key = key(resource.step)
        mode = if state.mode == :lose_release_and_inspection, do: :inspect_unavailable, else: :normal

        {:reply, reply,
         %{state | resources: Map.delete(state.resources, key), closed: MapSet.put(state.closed, key), mode: mode}}
    end
  end

  defp resource(step) do
    {:ok, resource} = Resource.new(step, Jido.generate_id(), Jido.generate_id(), :running)
    resource
  end

  defp observation(resources, step, nil), do: Map.get(resources, key(step), :absent)

  defp observation(resources, step, id) do
    case Enum.find(Map.values(resources), &(&1.id == id)) do
      nil -> :absent
      resource -> %{resource | step: step}
    end
  end

  defp acquisition_reply(:ok, :lose_acquire_reply, _), do: {:error, {:indeterminate, :timeout}}
  defp acquisition_reply(:ok, _, resource), do: {:ok, resource}
  defp acquisition_reply(error, _, _), do: {:error, {:indeterminate, {:boot_failed, error}}}

  defp boot(nil, _), do: :ok

  defp boot({host, options}, step) do
    options = Keyword.put(options, :provider_step, Step.to_record(step))

    case :erpc.call(host, DynamicSupervisor, :start_child, [
           JidoCluster.Test.Supervisor,
           {Jido.Cluster.HostRuntime, options}
         ]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      error -> error
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp key(step), do: Step.to_record(step) |> Jason.encode!()
end
