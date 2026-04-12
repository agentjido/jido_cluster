defmodule JidoCluster.InstanceManager do
  @moduledoc """
  Distributed wrapper around `Jido.Agent.InstanceManager`.

  This module routes keyed agent operations to a deterministic owner node and
  keeps singleton semantics per `{manager, key}` across the connected cluster.
  """

  use Supervisor

  alias Jido.Cluster.LeaseBackend
  alias JidoCluster.ClusterFormation
  alias JidoCluster.Internal.InstanceManagerConfig
  alias JidoCluster.Internal.Remote
  alias JidoCluster.KeyRuntime
  alias JidoCluster.LeaseStore
  alias JidoCluster.PartitionMonitor
  alias JidoCluster.Rebalancer
  alias JidoCluster.StorageCapabilities
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
    cluster_config = extract_cluster_config(opts)
    manager_config = extract_manager_config(opts, manager, cluster_config)
    :ok = InstanceManagerConfig.put_cluster(manager, cluster_config)
    :ok = InstanceManagerConfig.put_manager(manager, manager_config)

    children =
      if live_transfer?(cluster_config) do
        [
          Jido.child_spec(name: manager_config.jido),
          {Registry, keys: :unique, name: KeyRuntime.registry_name(manager)},
          {DynamicSupervisor, strategy: :one_for_one, name: KeyRuntime.dynamic_supervisor_name(manager)}
        ]
      else
        local_manager_opts = extract_local_manager_opts(opts, manager_config)
        [Jido.Agent.InstanceManager.child_spec(local_manager_opts)]
      end

    children = maybe_add_cluster_formation(children, opts)
    children = maybe_add_partition_monitor(children, manager, cluster_config)
    children = maybe_add_rebalancer(children, opts, manager, cluster_config)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Gets or starts an agent by key on the owner node."
  @spec get(manager(), key(), keyword()) :: {:ok, pid()} | {:error, term()}
  def get(manager, key, opts \\ []) do
    with :ok <- ensure_cluster_available(manager) do
      cond do
        live_transfer?(manager) ->
          timeout_ms = Keyword.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms)

          with {:ok, _placement} <- KeyRuntime.ensure_replica_set(manager, key, opts, timeout_ms),
               owner <- KeyRuntime.owner_node(manager, key, timeout_ms),
               {:ok, {:ok, pid}} <- Remote.rpc(owner, KeyRuntime, :primary_pid, [manager, key], timeout_ms) do
            {:ok, pid}
          else
            {:error, reason} -> {:error, reason}
            {:ok, other} -> {:error, {:unexpected_get_result, other}}
          end

        lease_backend?(manager) ->
          with :ok <- ensure_local_lease(manager, key),
               {:ok, pid} <- Jido.Agent.InstanceManager.get(manager, key, opts) do
            {:ok, pid}
          end

        true ->
          owner = owner_node(manager, key)
          timeout_ms = Keyword.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms)
          rpc_result = rpc_get_with_recovery_telemetry(manager, key, owner, opts, timeout_ms)

          case rpc_result do
            {:ok, {:ok, pid}} when is_pid(pid) -> {:ok, pid}
            {:ok, {:error, _reason} = error} -> error
            {:ok, other} -> {:error, {:unexpected_get_result, other}}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @doc "Looks up an existing agent by key on the owner node."
  @spec lookup(manager(), key()) :: {:ok, pid()} | :error
  def lookup(manager, key) do
    if cluster_available?(manager) do
      cond do
        live_transfer?(manager) ->
          owner = KeyRuntime.owner_node(manager, key, @default_rpc_timeout_ms)

          case Remote.rpc(owner, KeyRuntime, :primary_pid, [manager, key], @default_rpc_timeout_ms) do
            {:ok, {:ok, pid}} when is_pid(pid) -> {:ok, pid}
            _ -> :error
          end

        lease_backend?(manager) ->
          case lease_owner_node(manager, key) do
            {:ok, owner} ->
              if owner == Node.self() do
                Jido.Agent.InstanceManager.lookup(manager, key)
              else
                :error
              end

            _ ->
              :error
          end

        true ->
          owner = owner_node(manager, key)

          case Remote.rpc(owner, Jido.Agent.InstanceManager, :lookup, [manager, key], @default_rpc_timeout_ms) do
            {:ok, {:ok, pid}} when is_pid(pid) -> {:ok, pid}
            {:ok, :error} -> lookup_any_node(manager, key)
            {:ok, _other} -> lookup_any_node(manager, key)
            {:error, _reason} -> lookup_any_node(manager, key)
          end
      end
    else
      :error
    end
  end

  @doc "Routes a synchronous signal call through the distributed manager."
  @spec call(manager(), key(), Jido.Signal.t(), timeout()) :: {:ok, struct()} | {:error, term()}
  def call(manager, key, signal, timeout \\ @default_rpc_timeout_ms) do
    cond do
      live_transfer?(manager) ->
        with :ok <- ensure_cluster_available(manager),
             {:ok, _} <- KeyRuntime.ensure_replica_set(manager, key, [], timeout) do
          KeyRuntime.cluster_call(manager, key, signal, timeout)
        end

      lease_backend?(manager) ->
        with :ok <- ensure_local_lease(manager, key),
             {:ok, pid} <- Jido.Agent.InstanceManager.get(manager, key, []),
             {:ok, agent} <- Jido.AgentServer.call(pid, signal, timeout),
             :ok <- persist_acknowledged_state(manager, key, agent) do
          {:ok, agent}
        end

      true ->
        with {:ok, pid} <- get(manager, key),
             {:ok, agent} <- Jido.AgentServer.call(pid, signal, timeout),
             :ok <- persist_acknowledged_state(manager, key, agent) do
          {:ok, agent}
        end
    end
  end

  @doc "Routes an asynchronous signal cast through the distributed manager."
  @spec cast(manager(), key(), Jido.Signal.t()) :: :ok | {:error, term()}
  def cast(manager, key, signal) do
    cond do
      live_transfer?(manager) ->
        with :ok <- ensure_cluster_available(manager),
             {:ok, _} <- KeyRuntime.ensure_replica_set(manager, key, [], @default_rpc_timeout_ms) do
          KeyRuntime.cluster_cast(manager, key, signal, @default_rpc_timeout_ms)
        end

      lease_backend?(manager) ->
        with :ok <- ensure_local_lease(manager, key),
             {:ok, pid} <- Jido.Agent.InstanceManager.get(manager, key, []) do
          Jido.AgentServer.cast(pid, signal)
        end

      true ->
        with {:ok, pid} <- get(manager, key) do
          Jido.AgentServer.cast(pid, signal)
        end
    end
  end

  @doc "Stops an agent by key on the node where it currently exists."
  @spec stop(manager(), key()) :: :ok | {:error, :not_found} | {:error, term()}
  def stop(manager, key) do
    with :ok <- ensure_cluster_available(manager) do
      cond do
        live_transfer?(manager) ->
          KeyRuntime.stop_cluster(manager, key, @default_rpc_timeout_ms)

        lease_backend?(manager) ->
          stop_disconnected(manager, key)

        true ->
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
    end
  end

  @doc "Returns the deterministic owner node for a key."
  @spec owner_node(manager(), key()) :: node()
  def owner_node(manager, key) do
    cond do
      live_transfer?(manager) ->
        KeyRuntime.owner_node(manager, key, @default_rpc_timeout_ms)

      lease_backend?(manager) ->
        case lease_owner_node(manager, key) do
          {:ok, owner} when is_atom(owner) -> owner
          _ -> Node.self()
        end

      true ->
        Topology.owner_node(manager, key, Topology.connected_nodes())
    end
  end

  @doc "Returns manager counts by node and total active keys in cluster view."
  @spec stats(manager()) :: %{by_node: %{node() => non_neg_integer()}, total: non_neg_integer()}
  def stats(manager) do
    by_node =
      cond do
        live_transfer?(manager) ->
          Topology.connected_nodes()
          |> Enum.reduce(%{}, fn node, acc ->
            case Remote.rpc(node, KeyRuntime, :primary_keys, [manager], @default_rpc_timeout_ms) do
              {:ok, keys} when is_list(keys) -> Map.put(acc, node, length(keys))
              _ -> Map.put(acc, node, 0)
            end
          end)

        lease_backend?(manager) ->
          local_count =
            case Jido.Agent.InstanceManager.stats(manager) do
              %{count: count} when is_integer(count) and count >= 0 -> count
              _ -> 0
            end

          %{Node.self() => local_count}

        true ->
          Topology.connected_nodes()
          |> Enum.reduce(%{}, fn node, acc ->
            case Remote.rpc(node, Jido.Agent.InstanceManager, :stats, [manager], @default_rpc_timeout_ms) do
              {:ok, %{count: count}} when is_integer(count) and count >= 0 ->
                Map.put(acc, node, count)

              _ ->
                Map.put(acc, node, 0)
            end
          end)
      end

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
        children ++ [ClusterFormation.child_spec(name: ClusterFormation)]

      formation_opts when is_list(formation_opts) ->
        children ++ [ClusterFormation.child_spec(formation_opts)]
    end
  end

  defp maybe_add_partition_monitor(children, manager, %{coordination_backend: :connected_beam} = cluster_config) do
    children ++
      [
        PartitionMonitor.child_spec(
          manager: manager,
          partition_policy: cluster_config.partition_policy,
          min_quorum_nodes: cluster_config.min_quorum_nodes,
          coordination_backend: cluster_config.coordination_backend
        )
      ]
  end

  defp maybe_add_partition_monitor(children, _manager, _cluster_config), do: children

  defp maybe_add_rebalancer(children, _opts, _manager, %{coordination_backend: {:bedrock_lease, _backend}}),
    do: children

  defp maybe_add_rebalancer(children, opts, manager, _cluster_config) do
    if Keyword.get(opts, :rebalance, true) do
      rebalancer_opts =
        opts
        |> extract_rebalancer_opts(manager)

      children ++ [Rebalancer.child_spec(rebalancer_opts)]
    else
      children
    end
  end

  defp extract_local_manager_opts(opts, manager_config) do
    opts
    |> Keyword.take([
      :name,
      :agent,
      :idle_timeout,
      :storage,
      :registry_partitions,
      :agent_opts
    ])
    |> Keyword.put(:jido, manager_config.jido)
  end

  defp extract_manager_config(opts, manager, cluster_config) do
    %{
      agent: Keyword.fetch!(opts, :agent),
      jido: resolve_manager_jido(opts, manager, cluster_config),
      idle_timeout: Keyword.get(opts, :idle_timeout, :infinity),
      storage: Keyword.get(opts, :storage, nil),
      agent_opts: Keyword.get(opts, :agent_opts, [])
    }
  end

  defp resolve_manager_jido(opts, manager, cluster_config) do
    Keyword.get(opts, :jido) ||
      Keyword.get(Keyword.get(opts, :agent_opts, []), :jido) ||
      default_manager_jido(manager, cluster_config)
  end

  defp default_manager_jido(manager, %{handoff_mode: :live_transfer}) do
    Module.concat(__MODULE__, "Jido.#{manager}")
  end

  defp default_manager_jido(_manager, _cluster_config), do: Jido

  defp extract_rebalancer_opts(opts, manager) do
    [
      manager: manager,
      interval_ms: Keyword.get(opts, :rebalance_interval_ms, 30_000),
      max_migrations_per_tick: Keyword.get(opts, :max_migrations_per_tick, 1),
      rpc_timeout_ms: Keyword.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms),
      storage: Keyword.get(opts, :storage, :auto)
    ]
  end

  defp extract_cluster_config(opts) do
    %{
      partition_policy: validate_partition_policy(Keyword.get(opts, :partition_policy, :freeze)),
      min_quorum_nodes: validate_min_quorum_nodes(Keyword.get(opts, :min_quorum_nodes, 1)),
      handoff_mode: validate_handoff_mode(Keyword.get(opts, :handoff_mode, :hibernate_thaw)),
      coordination_backend: validate_coordination_backend(Keyword.get(opts, :coordination_backend, :connected_beam)),
      replication:
        validate_replication(Keyword.get(opts, :replication, %{replicas: 0, mode: :async, promotion_timeout_ms: 5_000}))
    }
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

  defp stop_disconnected(manager, key) do
    stop_result =
      case Jido.Agent.InstanceManager.stop(manager, key) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end

    case {stop_result, lease_backend(manager)} do
      {:ok, {:ok, %LeaseBackend{} = backend}} ->
        case LeaseStore.release(manager, key, Node.self(), backend) do
          :ok -> :ok
          {:error, :stale} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        :ok
    end
  end

  defp ensure_cluster_available(manager) do
    if cluster_available?(manager) do
      :ok
    else
      {:error, :cluster_unavailable}
    end
  end

  defp cluster_available?(manager) do
    InstanceManagerConfig.cluster_available?(manager, Topology.connected_nodes())
  end

  defp ensure_local_lease(manager, key) do
    case lease_backend(manager) do
      {:ok, %LeaseBackend{} = backend} ->
        case LeaseStore.acquire_or_renew(manager, key, Node.self(), backend) do
          {:ok, _lease} ->
            :ok

          {:error, :lease_unavailable} ->
            maybe_stop_local_runtime(manager, key)
            {:error, :lease_unavailable}

          {:error, :stale} ->
            maybe_stop_local_runtime(manager, key)
            {:error, :lease_unavailable}

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, :invalid_coordination_backend}
    end
  end

  defp maybe_stop_local_runtime(manager, key) do
    case Jido.Agent.InstanceManager.stop(manager, key) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp lease_owner_node(manager, key) do
    with {:ok, %LeaseBackend{} = backend} <- lease_backend(manager) do
      LeaseStore.current_holder(manager, key, backend)
    end
  end

  defp lease_backend(manager) do
    case InstanceManagerConfig.fetch_cluster(manager) do
      {:ok, %{coordination_backend: {:bedrock_lease, %LeaseBackend{} = backend}}} -> {:ok, backend}
      _ -> :error
    end
  end

  defp persist_acknowledged_state(manager, key, agent) do
    case InstanceManagerConfig.fetch(manager) do
      {:ok, %{storage: storage, agent: agent_module}} ->
        maybe_persist_shared_state(storage, agent_module, manager, key, agent)

      :error ->
        :ok
    end
  end

  defp maybe_persist_shared_state(nil, _agent_module, _manager, _key, _agent), do: :ok

  defp maybe_persist_shared_state(storage, agent_module, manager, key, agent) do
    if StorageCapabilities.shared_backend?(storage) do
      Jido.Persist.hibernate(storage, agent_module, {manager, key}, agent)
    else
      :ok
    end
  end

  defp rpc_get_with_recovery_telemetry(manager, key, owner, opts, timeout_ms) do
    case recovery_metadata(manager, key, owner, timeout_ms) do
      {:ok, metadata} ->
        started_at = System.monotonic_time()
        emit_recovery(:start, %{count: 1}, metadata)

        result = Remote.rpc(owner, Jido.Agent.InstanceManager, :get, [manager, key, opts], timeout_ms)
        elapsed_ms = System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

        case result do
          {:ok, {:ok, pid}} when is_pid(pid) ->
            emit_recovery(:success, %{count: 1, duration_ms: elapsed_ms}, metadata)

          {:ok, {:error, reason}} ->
            emit_recovery(:failure, %{count: 1, duration_ms: elapsed_ms}, Map.put(metadata, :reason, reason))

          {:error, reason} ->
            emit_recovery(:failure, %{count: 1, duration_ms: elapsed_ms}, Map.put(metadata, :reason, reason))

          other ->
            emit_recovery(
              :failure,
              %{count: 1, duration_ms: elapsed_ms},
              Map.put(metadata, :reason, {:unexpected_get_result, other})
            )
        end

        result

      :no_recovery ->
        Remote.rpc(owner, Jido.Agent.InstanceManager, :get, [manager, key, opts], timeout_ms)
    end
  end

  defp recovery_metadata(manager, key, owner, timeout_ms) do
    with {:ok, %{storage: storage}} <- InstanceManagerConfig.fetch(manager),
         true <- StorageCapabilities.shared_backend?(storage),
         true <- runtime_missing?(owner, manager, key, timeout_ms) do
      {:ok,
       %{
         manager: manager,
         key: key,
         owner: owner,
         storage_backend: storage_backend_name(storage)
       }}
    else
      _ -> :no_recovery
    end
  end

  defp runtime_missing?(owner, manager, key, timeout_ms) do
    case Remote.rpc(owner, Jido.Agent.InstanceManager, :lookup, [manager, key], timeout_ms) do
      {:ok, :error} -> true
      {:ok, {:ok, _pid}} -> false
      {:ok, _other} -> true
      {:error, _reason} -> false
    end
  end

  defp storage_backend_name({storage_module, _opts}) when is_atom(storage_module), do: storage_module
  defp storage_backend_name(storage_module) when is_atom(storage_module), do: storage_module

  defp emit_recovery(stage, measurements, metadata) do
    :telemetry.execute([:jido_cluster, :instance_manager, :recovery, stage], measurements, metadata)
  end

  defp validate_partition_policy(:freeze), do: :freeze
  defp validate_partition_policy(:soft_owner), do: :soft_owner

  defp validate_partition_policy(other) do
    raise ArgumentError,
          "Invalid :partition_policy for JidoCluster.InstanceManager; expected :freeze, got: #{inspect(other)}"
  end

  defp validate_min_quorum_nodes(value) when is_integer(value) and value > 0, do: value

  defp validate_min_quorum_nodes(other) do
    raise ArgumentError,
          "Invalid :min_quorum_nodes for JidoCluster.InstanceManager; expected positive integer, got: #{inspect(other)}"
  end

  defp validate_handoff_mode(:hibernate_thaw), do: :hibernate_thaw
  defp validate_handoff_mode(:live_transfer), do: :live_transfer

  defp validate_handoff_mode(other) do
    raise ArgumentError,
          "Invalid :handoff_mode for JidoCluster.InstanceManager; expected :hibernate_thaw, got: #{inspect(other)}"
  end

  defp validate_coordination_backend(:connected_beam), do: :connected_beam

  defp validate_coordination_backend({:bedrock_lease, lease_opts}) when is_list(lease_opts) do
    case LeaseBackend.new(lease_opts) do
      {:ok, %LeaseBackend{} = backend} ->
        {:bedrock_lease, backend}

      {:error, _reason} ->
        raise ArgumentError,
              "Invalid :coordination_backend for JidoCluster.InstanceManager; expected {:bedrock_lease, opts} with a valid lease backend config, got: #{inspect({:bedrock_lease, lease_opts})}"
    end
  end

  defp validate_coordination_backend(other) do
    raise ArgumentError,
          "Invalid :coordination_backend for JidoCluster.InstanceManager; expected :connected_beam or {:bedrock_lease, opts}, got: #{inspect(other)}"
  end

  defp validate_replication(replication) do
    case Jido.Cluster.Replication.new(replication) do
      {:ok, %Jido.Cluster.Replication{} = parsed} ->
        parsed

      {:error, _reason} ->
        raise ArgumentError,
              "Invalid :replication for JidoCluster.InstanceManager; expected %{replicas: 0|1, mode: :async|:sync, promotion_timeout_ms: positive_integer}, got: #{inspect(replication)}"
    end
  end

  defp node_for_lookup_result({:ok, pid}) when is_pid(pid), do: {:ok, node(pid)}

  defp live_transfer?(manager) when is_atom(manager) do
    case InstanceManagerConfig.fetch_cluster(manager) do
      {:ok, %{handoff_mode: :live_transfer}} -> true
      _ -> false
    end
  end

  defp live_transfer?(%{handoff_mode: :live_transfer}), do: true
  defp live_transfer?(_), do: false

  defp lease_backend?(manager) when is_atom(manager) do
    case InstanceManagerConfig.fetch_cluster(manager) do
      {:ok, %{coordination_backend: {:bedrock_lease, %LeaseBackend{}}}} -> true
      _ -> false
    end
  end
end
