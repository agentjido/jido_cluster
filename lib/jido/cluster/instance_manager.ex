defmodule Jido.Cluster.InstanceManager do
  @moduledoc """
  Routes keyed Jido V3 Agents across connected manager nodes.

  Only nodes with a live manager participate in placement and quorum checks.
  A connected-cluster lock serializes work for each `{manager, key}`. Before
  starting work on a new owner, the manager stops any prior connected owner.
  Jido persists each committed Turn when `:persistence` is configured.

  This is an alpha foundation. A connected BEAM view is not a durable writer
  lease. A timeout can have an unknown result; this module never retries a
  Signal automatically. Use manager calls rather than writing through a pid.
  """
  use Supervisor

  alias Jido.Cluster.{Config, Topology}
  alias Jido.Cluster.Internal.LocalManager

  @type manager :: atom()
  @type key :: term()

  @doc "Starts a manager under the package DynamicSupervisor."
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  def start(opts), do: DynamicSupervisor.start_child(Jido.Cluster.ManagerSupervisor, {__MODULE__, opts})

  @doc "Returns the supervisor child specification for a manager."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @doc "Starts a manager and its Jido instance."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    with {:ok, config} <- Config.new(opts) do
      Supervisor.start_link(__MODULE__, config, name: supervisor_name(config.name))
    end
  end

  @impl true
  def init(config) do
    children = [
      {Jido, name: config.jido, namespace: config.namespace, persistence: config.persistence},
      {LocalManager, config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Gets or starts the current keyed Agent. The pid is a temporary observation."
  @spec get(manager(), key(), keyword()) :: {:ok, pid()} | {:error, term()}
  def get(manager, key, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) -- [:initial_state] == [],
      do: route(manager, key, {:get, opts}, 5_000),
      else: {:error, :invalid_get_options}
  end

  @doc "Looks up the Agent on its current placement node without starting it."
  @spec lookup(manager(), key()) :: {:ok, pid()} | :error | {:error, term()}
  def lookup(manager, key), do: route(manager, key, :lookup, 5_000)

  @doc "Applies a Signal and returns the committed Jido V3 Agent."
  @spec call(manager(), key(), Jido.Signal.t(), timeout()) :: {:ok, Jido.Agent.t()} | {:error, term()}
  def call(manager, key, signal, timeout \\ 5_000)
  def call(manager, key, %Jido.Signal{} = signal, timeout), do: route(manager, key, {:call, signal}, timeout)
  def call(_manager, _key, _signal, _timeout), do: {:error, :invalid_signal}

  @doc "Enqueues a Signal. Success does not acknowledge its commit or persistence."
  @spec cast(manager(), key(), Jido.Signal.t()) :: :ok | {:error, term()}
  def cast(manager, key, %Jido.Signal{} = signal), do: route(manager, key, {:cast, signal}, 5_000)
  def cast(_manager, _key, _signal), do: {:error, :invalid_signal}

  @doc "Stops the keyed activation. Its persistence record remains for recovery."
  @spec stop(manager(), key()) :: :ok | {:error, term()}
  def stop(manager, key), do: route(manager, key, :stop, 5_000)

  @doc "Returns the current placement node, or nil when no manager is visible."
  @spec owner_node(manager(), key()) :: node() | nil
  def owner_node(manager, key) do
    case members(manager) do
      [] -> nil
      nodes -> Topology.owner_node(manager, key, nodes)
    end
  end

  @doc "Returns the participating manager nodes in node-name order."
  @spec members(manager()) :: [node()]
  def members(manager) do
    :pg.get_members(Jido.Cluster.PG, {:manager, manager}) |> Enum.map(&node/1) |> Enum.uniq() |> Enum.sort()
  end

  @doc "Returns visible active key counts. Unreachable managers are reported as errors."
  @spec stats(manager()) :: map()
  def stats(manager) do
    Enum.reduce(members(manager), %{by_node: %{}, total: 0, errors: %{}}, fn worker, acc ->
      case rpc(worker, LocalManager, :stats, [manager], 5_000) do
        %{count: count} -> %{acc | by_node: Map.put(acc.by_node, worker, count), total: acc.total + count}
        error -> %{acc | errors: Map.put(acc.errors, worker, error)}
      end
    end)
  end

  @doc "Returns a stable binary Agent ID for a portable logical key."
  @spec agent_id(key()) :: String.t()
  def agent_id(key), do: "key:" <> Base.url_encode64(:erlang.term_to_binary(key, [:deterministic]), padding: false)

  @doc "Returns the manager supervisor name."
  @spec supervisor_name(manager()) :: atom()
  def supervisor_name(manager), do: Module.concat(__MODULE__.Supervisor, manager)

  @doc false
  @spec dispatch(manager(), key(), term(), timeout()) :: term()
  def dispatch(manager, key, operation, timeout) do
    config = LocalManager.config(manager)
    nodes = members(manager)

    with :ok <- available(config, nodes),
         true <- Topology.owner_node(manager, key, nodes) == node() do
      result =
        :global.trans(
          {{__MODULE__, manager, key}, self()},
          fn -> run_locked(config, key, operation, nodes, timeout) end,
          nodes
        )

      if result == :aborted, do: {:error, :cluster_busy}, else: result
    else
      false -> {:error, :topology_changed}
      {:error, _} = error -> error
    end
  end

  defp run_locked(config, key, operation, nodes, timeout) do
    with true <- nodes == members(config.name),
         :ok <- compatible_managers(config, nodes, timeout) do
      execute_locked(config.name, key, operation, nodes, timeout)
    else
      false -> {:error, :topology_changed}
      {:error, _} = error -> error
    end
  end

  defp execute_locked(manager, key, :stop, nodes, timeout) do
    Enum.reduce_while(nodes, {:error, :not_found}, fn worker, acc ->
      case rpc(worker, LocalManager, :stop, [manager, key, timeout], timeout) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, acc}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp execute_locked(manager, key, operation, nodes, timeout) do
    with :ok <- reconcile(manager, key, nodes, operation, timeout),
         do: execute(manager, key, operation, timeout)
  end

  defp route(manager, key, operation, timeout) do
    cond do
      not Jido.PortableTerm.valid?(key) ->
        {:error, :invalid_key}

      timeout != :infinity and not (is_integer(timeout) and timeout > 0) ->
        {:error, :invalid_timeout}

      true ->
        case owner_node(manager, key) do
          nil -> {:error, :manager_unavailable}
          owner -> rpc(owner, __MODULE__, :dispatch, [manager, key, operation, timeout], timeout)
        end
    end
  end

  defp rpc(worker, module, function, args, timeout) do
    :erpc.call(worker, module, function, args, timeout)
  catch
    kind, reason -> {:error, {:rpc_failed, worker, kind, reason}}
  end

  defp available(config, nodes) do
    if length(nodes) >= config.min_quorum_nodes, do: :ok, else: {:error, :cluster_unavailable}
  end

  defp compatible_managers(config, nodes, timeout) do
    Enum.reduce_while(nodes, :ok, fn worker, :ok ->
      case rpc(worker, LocalManager, :config, [config.name], timeout) do
        ^config -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :incompatible_manager_config}}
      end
    end)
  end

  defp reconcile(_manager, _key, _nodes, :lookup, _timeout), do: :ok

  defp reconcile(manager, key, nodes, _operation, timeout) do
    Enum.reduce_while(nodes -- [node()], :ok, fn worker, :ok ->
      case rpc(worker, LocalManager, :stop, [manager, key, timeout], timeout) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp execute(manager, key, {:get, opts}, timeout), do: LocalManager.get(manager, key, opts, timeout)
  defp execute(manager, key, :lookup, _timeout), do: LocalManager.lookup(manager, key)

  defp execute(manager, key, {:call, signal}, timeout) do
    with {:ok, pid} <- LocalManager.get(manager, key, [], timeout), do: Jido.AgentServer.call(pid, signal, timeout)
  end

  defp execute(manager, key, {:cast, signal}, timeout) do
    with {:ok, pid} <- LocalManager.get(manager, key, [], timeout), do: Jido.AgentServer.cast(pid, signal)
  end
end
