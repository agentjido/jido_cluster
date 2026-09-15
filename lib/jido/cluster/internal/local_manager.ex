defmodule Jido.Cluster.Internal.LocalManager do
  @moduledoc false
  use GenServer

  alias Jido.Cluster.InstanceManager

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: config.name)

  def config(manager), do: GenServer.call(manager, :config)
  def get(manager, key, opts, timeout), do: GenServer.call(manager, {:get, key, opts}, timeout)
  def lookup(manager, key), do: GenServer.call(manager, {:lookup, key})
  def stop(manager, key, timeout), do: GenServer.call(manager, {:stop, key, timeout}, timeout)
  def stats(manager), do: GenServer.call(manager, :stats)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    :ok = :pg.join(Jido.Cluster.PG, {:manager, config.name}, self())
    Process.send_after(self(), :check_quorum, 100)
    {:ok, %{config: config, agents: %{}}}
  end

  @impl true
  def handle_call(:config, _from, state), do: {:reply, state.config, state}

  def handle_call({:lookup, key}, _from, state), do: {:reply, lookup_live(state, key), state}

  def handle_call(:stats, _from, state) do
    keys = for {key, {pid, _ref}} <- state.agents, Process.alive?(pid), do: key
    {:reply, %{count: length(keys), keys: Enum.sort(keys)}, state}
  end

  def handle_call({:get, key, opts}, _from, state) do
    config = state.config
    nodes = InstanceManager.members(config.name)

    cond do
      length(nodes) < config.min_quorum_nodes ->
        {:reply, {:error, :cluster_unavailable}, stop_all(state)}

      InstanceManager.owner_node(config.name, key) != node() ->
        {:reply, {:error, :topology_changed}, state}

      true ->
        case lookup_live(state, key) do
          {:ok, _pid} = result -> {:reply, result, state}
          :error -> start_agent(state, key, opts)
        end
    end
  end

  def handle_call({:stop, key, timeout}, _from, state) do
    case Map.pop(state.agents, key) do
      {nil, _agents} ->
        {:reply, {:error, :not_found}, state}

      {{pid, ref}, agents} ->
        result = stop_agent(pid, timeout)

        if result == :ok do
          Process.demonitor(ref, [:flush])
          {:reply, :ok, %{state | agents: agents}}
        else
          {:reply, result, state}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    agents = Map.reject(state.agents, fn {_key, {_pid, monitor}} -> monitor == ref end)
    {:noreply, %{state | agents: agents}}
  end

  def handle_info(:check_quorum, state) do
    next =
      if length(InstanceManager.members(state.config.name)) < state.config.min_quorum_nodes,
        do: stop_all(state),
        else: state

    Process.send_after(self(), :check_quorum, 100)
    {:noreply, next}
  end

  @impl true
  def terminate(_reason, state) do
    stop_all(state)
    :ok
  end

  defp lookup_live(state, key) do
    case Map.get(state.agents, key) do
      {pid, _ref} -> if Process.alive?(pid), do: {:ok, pid}, else: :error
      nil -> :error
    end
  end

  defp start_agent(state, key, opts) do
    config = state.config

    agent_opts =
      config.agent_opts ++
        [
          id: InstanceManager.agent_id(key),
          persistence: config.persistence,
          idle_timeout: config.idle_timeout,
          restart: :temporary,
          initial_state: Keyword.get(opts, :initial_state)
        ]

    case Jido.start_agent(config.jido, config.agent, agent_opts) do
      {:ok, pid} = result ->
        ref = Process.monitor(pid)
        {:reply, result, %{state | agents: Map.put(state.agents, key, {pid, ref})}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp stop_agent(pid, timeout) do
    Jido.AgentServer.stop(pid, :shutdown, timeout)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _} -> :ok
    :exit, reason -> {:error, {:stop_failed, reason}}
  end

  defp stop_all(state) do
    agents =
      Map.reject(state.agents, fn {_key, {pid, ref}} ->
        if stop_agent(pid, 5_000) == :ok do
          Process.demonitor(ref, [:flush])
          true
        else
          false
        end
      end)

    %{state | agents: agents}
  end
end
