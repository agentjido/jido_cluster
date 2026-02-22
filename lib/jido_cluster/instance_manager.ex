defmodule JidoCluster.InstanceManager do
  @moduledoc """
  Distributed wrapper around `Jido.Agent.InstanceManager`.

  This module routes keyed agent operations to a deterministic owner node and
  keeps singleton semantics per `{manager, key}` across the connected cluster.
  """

  use Supervisor

  alias JidoCluster.ClusterFormation
  alias JidoCluster.Internal.Remote
  alias JidoCluster.Rebalancer
  alias JidoCluster.Topology

  @default_rpc_timeout_ms 5_000

  @type manager :: atom()
  @type key :: term()

  @doc """
  Starts a distributed manager under the app-level dynamic supervisor.

  This helper is useful when starting managers at runtime (for example in tests
  or dynamic environments).
  """
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  def start(opts) do
    DynamicSupervisor.start_child(
      JidoCluster.InstanceManager.DynamicSupervisor,
      {__MODULE__, opts}
    )
  end

  @doc "Starts distributed manager components for a single manager name."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    manager = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, manager},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    manager = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: supervisor_name(manager))
  end

  @impl true
  def init(opts) do
    manager = Keyword.fetch!(opts, :name)

    children = []
    children = maybe_add_cluster_formation(children, opts)

    local_manager_opts = extract_local_manager_opts(opts)
    children = [Jido.Agent.InstanceManager.child_spec(local_manager_opts) | children]

    if Keyword.get(opts, :rebalance, true) do
      rebalancer_opts =
        opts
        |> extract_rebalancer_opts(manager)

      children = [Rebalancer.child_spec(rebalancer_opts) | children]
      Supervisor.init(children, strategy: :one_for_one)
    else
      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  @doc "Gets or starts an agent by key on the owner node."
  @spec get(manager(), key(), keyword()) :: {:ok, pid()} | {:error, term()}
  def get(manager, key, opts \\ []) do
    owner = owner_node(manager, key)
    timeout_ms = Keyword.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms)

    case Remote.rpc(owner, Jido.Agent.InstanceManager, :get, [manager, key, opts], timeout_ms) do
      {:ok, {:ok, pid}} when is_pid(pid) -> {:ok, pid}
      {:ok, {:error, _reason} = error} -> error
      {:ok, other} -> {:error, {:unexpected_get_result, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Looks up an existing agent by key on the owner node."
  @spec lookup(manager(), key()) :: {:ok, pid()} | :error
  def lookup(manager, key) do
    owner = owner_node(manager, key)

    case Remote.rpc(owner, Jido.Agent.InstanceManager, :lookup, [manager, key], @default_rpc_timeout_ms) do
      {:ok, {:ok, pid}} when is_pid(pid) -> {:ok, pid}
      {:ok, :error} -> lookup_any_node(manager, key)
      {:ok, _other} -> lookup_any_node(manager, key)
      {:error, _reason} -> lookup_any_node(manager, key)
    end
  end

  @doc "Routes a synchronous signal call through the distributed manager."
  @spec call(manager(), key(), Jido.Signal.t(), timeout()) :: {:ok, struct()} | {:error, term()}
  def call(manager, key, signal, timeout \\ @default_rpc_timeout_ms) do
    with {:ok, pid} <- get(manager, key),
         {:ok, agent} <- Jido.AgentServer.call(pid, signal, timeout) do
      {:ok, agent}
    end
  end

  @doc "Routes an asynchronous signal cast through the distributed manager."
  @spec cast(manager(), key(), Jido.Signal.t()) :: :ok | {:error, term()}
  def cast(manager, key, signal) do
    with {:ok, pid} <- get(manager, key) do
      Jido.AgentServer.cast(pid, signal)
    end
  end

  @doc "Stops an agent by key on the node where it currently exists."
  @spec stop(manager(), key()) :: :ok | {:error, :not_found} | {:error, term()}
  def stop(manager, key) do
    owner = owner_node(manager, key)

    case Remote.rpc(owner, Jido.Agent.InstanceManager, :stop, [manager, key], @default_rpc_timeout_ms) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, :not_found}} ->
        stop_any_node(manager, key)

      {:ok, {:error, _} = error} ->
        error

      {:ok, other} ->
        {:error, {:unexpected_stop_result, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Returns the deterministic owner node for a key."
  @spec owner_node(manager(), key()) :: node()
  def owner_node(manager, key) do
    Topology.owner_node(manager, key, Topology.connected_nodes())
  end

  @doc "Returns manager counts by node and total active keys in cluster view."
  @spec stats(manager()) :: %{by_node: %{node() => non_neg_integer()}, total: non_neg_integer()}
  def stats(manager) do
    by_node =
      Topology.connected_nodes()
      |> Enum.reduce(%{}, fn node, acc ->
        case Remote.rpc(node, Jido.Agent.InstanceManager, :stats, [manager], @default_rpc_timeout_ms) do
          {:ok, %{count: count}} when is_integer(count) and count >= 0 ->
            Map.put(acc, node, count)

          _ ->
            Map.put(acc, node, 0)
        end
      end)

    total = Enum.reduce(by_node, 0, fn {_node, count}, acc -> acc + count end)

    %{by_node: by_node, total: total}
  end

  @doc false
  @spec supervisor_name(manager()) :: atom()
  def supervisor_name(manager), do: Module.concat(__MODULE__, "Supervisor.#{manager}")

  defp maybe_add_cluster_formation(children, opts) do
    case Keyword.get(opts, :cluster_formation) do
      nil ->
        children

      false ->
        children

      true ->
        [ClusterFormation.child_spec(name: ClusterFormation) | children]

      formation_opts when is_list(formation_opts) ->
        [ClusterFormation.child_spec(formation_opts) | children]
    end
  end

  defp extract_local_manager_opts(opts) do
    opts
    |> Keyword.take([
      :name,
      :agent,
      :idle_timeout,
      :storage,
      :jido,
      :registry_partitions,
      :agent_opts
    ])
  end

  defp extract_rebalancer_opts(opts, manager) do
    [
      manager: manager,
      interval_ms: Keyword.get(opts, :rebalance_interval_ms, 30_000),
      max_migrations_per_tick: Keyword.get(opts, :max_migrations_per_tick, 1),
      rpc_timeout_ms: Keyword.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms),
      storage: Keyword.get(opts, :storage, :auto)
    ]
  end

  defp lookup_any_node(manager, key) do
    Enum.find_value(Topology.connected_nodes(), :error, fn node ->
      case Remote.rpc(node, Jido.Agent.InstanceManager, :lookup, [manager, key], @default_rpc_timeout_ms) do
        {:ok, {:ok, pid}} when is_pid(pid) -> {:ok, pid}
        _ -> false
      end
    end)
  end

  defp stop_any_node(manager, key) do
    case lookup_any_node(manager, key) do
      {:ok, _pid} = found ->
        {:ok, node} = node_for_lookup_result(found)

        case Remote.rpc(node, Jido.Agent.InstanceManager, :stop, [manager, key], @default_rpc_timeout_ms) do
          {:ok, result} -> result
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp node_for_lookup_result({:ok, pid}) when is_pid(pid), do: {:ok, node(pid)}
end
