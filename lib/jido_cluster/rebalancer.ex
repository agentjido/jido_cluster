defmodule JidoCluster.Rebalancer do
  @moduledoc """
  Conservative periodic rebalancer for distributed keyed agents.

  Behavior:

  - Runs on a fixed interval (default: 30s) with startup jitter.
  - Only the deterministic leader node executes migrations.
  - Migrates at most `:max_migrations_per_tick` keys per tick.
  - Skips migration for non-shared backends (for example ETS).
  """

  use GenServer

  require Logger

  alias JidoCluster.Internal.InstanceManagerConfig
  alias JidoCluster.Internal.Remote
  alias JidoCluster.StorageCapabilities
  alias JidoCluster.Topology

  @default_interval_ms 30_000
  @default_max_migrations 1
  @default_rpc_timeout_ms 5_000

  @type state :: %{
          manager: term(),
          interval_ms: pos_integer(),
          max_migrations_per_tick: pos_integer(),
          rpc_timeout_ms: pos_integer(),
          storage_config: :auto | nil | module() | {module(), keyword()}
        }

  @doc "Child specification for a manager-scoped rebalancer worker."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    manager = Keyword.fetch!(opts, :manager)

    %{
      id: {__MODULE__, manager},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    manager = Keyword.fetch!(opts, :manager)
    name = Keyword.get(opts, :name, name(manager))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec name(term()) :: atom()
  def name(manager), do: Module.concat(__MODULE__, "#{manager}")

  @doc "Forces an immediate rebalance tick (useful for tests)."
  @spec trigger(term()) :: :ok
  def trigger(manager) do
    GenServer.cast(name(manager), :trigger)
  end

  @doc "Forces an immediate rebalance tick and waits for completion (useful for tests)."
  @spec trigger_sync(term(), timeout()) :: :ok
  def trigger_sync(manager, timeout \\ 5_000) do
    GenServer.call(name(manager), :trigger_sync, timeout)
  end

  @impl true
  def init(opts) do
    state = %{
      manager: Keyword.fetch!(opts, :manager),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      max_migrations_per_tick: Keyword.get(opts, :max_migrations_per_tick, @default_max_migrations),
      rpc_timeout_ms: Keyword.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms),
      storage_config: Keyword.get(opts, :storage, :auto)
    }

    send_after_next_tick(state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_cast(:trigger, state) do
    do_tick(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:trigger_sync, _from, state) do
    do_tick(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    do_tick(state)
    send_after_next_tick(state.interval_ms)
    {:noreply, state}
  end

  defp send_after_next_tick(interval_ms) do
    jitter_ms = if interval_ms > 1, do: :rand.uniform(interval_ms) - 1, else: 0
    Process.send_after(self(), :tick, jitter_ms)
  end

  defp do_tick(state) do
    if leader?() do
      rebalance(state)
    end
  end

  defp leader? do
    case Topology.connected_nodes() do
      [] -> true
      nodes -> Node.self() == hd(nodes)
    end
  end

  defp rebalance(state) do
    nodes = Topology.connected_nodes()
    storage_config = resolve_storage_config(state)

    mismatches =
      state.manager
      |> collect_running_keys_by_source(nodes, state.rpc_timeout_ms)
      |> compute_mismatches(state.manager, nodes)
      |> Enum.take(state.max_migrations_per_tick)

    Enum.each(mismatches, fn {key, source, target} ->
      migrate_key(state.manager, key, source, target, storage_config, state.rpc_timeout_ms)
    end)
  end

  defp collect_running_keys_by_source(manager, nodes, timeout_ms) do
    Enum.reduce(nodes, %{}, fn node, acc ->
      case Remote.rpc(node, Jido.Agent.InstanceManager, :stats, [manager], timeout_ms) do
        {:ok, %{keys: keys}} when is_list(keys) ->
          Enum.reduce(keys, acc, fn key, key_acc ->
            Map.update(key_acc, key, node, fn existing -> min(existing, node) end)
          end)

        {:ok, _other} ->
          acc

        {:error, reason} ->
          Logger.debug("Rebalancer stats fetch failed on #{inspect(node)}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp compute_mismatches(key_sources, manager, nodes) do
    key_sources
    |> Enum.reduce([], fn {key, source}, acc ->
      target = Topology.owner_node(manager, key, nodes)

      if source == target do
        acc
      else
        [{key, source, target} | acc]
      end
    end)
    |> Enum.sort_by(fn {key, source, target} ->
      :erlang.term_to_binary({key, source, target})
    end)
  end

  defp migrate_key(manager, key, source, target, storage_config, timeout_ms) do
    if shared_backend?(storage_config) do
      emit(:start, %{manager: manager, key: key, from: source, to: target})

      case stop_then_get(manager, key, source, target, timeout_ms) do
        :ok ->
          emit(:success, %{manager: manager, key: key, from: source, to: target})

        {:error, reason} ->
          emit(:failure, %{manager: manager, key: key, from: source, to: target, reason: reason})
      end
    else
      emit(:skipped, %{
        manager: manager,
        key: key,
        from: source,
        to: target,
        reason: :non_shared_backend
      })
    end
  end

  defp stop_then_get(manager, key, source, target, timeout_ms) do
    with {:ok, stop_result} <- Remote.rpc(source, Jido.Agent.InstanceManager, :stop, [manager, key], timeout_ms),
         :ok <- validate_stop_result(stop_result),
         {:ok, get_result} <- Remote.rpc(target, Jido.Agent.InstanceManager, :get, [manager, key, []], timeout_ms),
         :ok <- validate_get_result(get_result) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp validate_stop_result(:ok), do: :ok
  defp validate_stop_result({:error, :not_found}), do: :ok
  defp validate_stop_result(other), do: {:error, {:stop_failed, other}}

  defp validate_get_result({:ok, pid}) when is_pid(pid), do: :ok
  defp validate_get_result(other), do: {:error, {:get_failed, other}}

  defp resolve_storage_config(%{storage_config: :auto, manager: manager}) do
    case InstanceManagerConfig.fetch_storage(manager) do
      :error -> nil
      storage -> storage
    end
  end

  defp resolve_storage_config(%{storage_config: storage}), do: storage

  defp shared_backend?(nil), do: false
  defp shared_backend?(storage), do: StorageCapabilities.shared_backend?(storage)

  defp emit(stage, metadata) when stage in [:start, :success, :failure, :skipped] do
    :telemetry.execute([:jido_cluster, :rebalancer, :migration, stage], %{count: 1}, metadata)
  end
end
