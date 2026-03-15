defmodule Jido.Cluster.InstanceManager do
  # covers: jido_cluster.package.public_namespace
  # covers: jido_cluster.instance_manager.manager_routed_singleton
  @moduledoc """
  Distributed wrapper around `Jido.Agent.InstanceManager`.

  Preferred public namespace for keyed agent management across connected nodes.
  Delegates to `JidoCluster.InstanceManager`.

  V1 ownership contract:

  - One logical key has one current primary and at most one standby.
  - Callers should route through this manager by `{manager, key}` instead of
    holding raw pids as a long-lived cross-node contract.
  - Returned pids are point-in-time observations of the current primary and may
    change after handoff, failover, or reconnect healing.
  - `owner_node/2` and `stats/1` expose the current cluster view rather than a
    globally durable truth.
  """

  @type manager :: atom()
  @type key :: term()

  @doc """
  Starts a distributed manager under the app-level dynamic supervisor.
  """
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  defdelegate start(opts), to: JidoCluster.InstanceManager

  @doc "Starts distributed manager components for a single manager name."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(opts), to: JidoCluster.InstanceManager

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(opts), to: JidoCluster.InstanceManager

  @doc """
  Gets or starts an agent by key on the current owner node.

  The returned pid is not a stable cluster identity. Callers should resolve
  ownership again through the manager after topology changes.
  """
  @spec get(manager(), key(), keyword()) :: {:ok, pid()} | {:error, term()}
  defdelegate get(manager, key, opts \\ []), to: JidoCluster.InstanceManager

  @doc """
  Looks up an existing agent by key on the current owner node.

  The returned pid is a short-lived observation of the active primary.
  """
  @spec lookup(manager(), key()) :: {:ok, pid()} | :error
  defdelegate lookup(manager, key), to: JidoCluster.InstanceManager

  @doc """
  Routes a synchronous signal call through the distributed manager.

  In live-transfer mode, acknowledged success implies the primary applied the
  signal and synchronized the standby to the same replicated sequence.
  """
  @spec call(manager(), key(), Jido.Signal.t(), timeout()) :: {:ok, struct()} | {:error, term()}
  defdelegate call(manager, key, signal, timeout \\ 5_000), to: JidoCluster.InstanceManager

  @doc """
  Routes an asynchronous signal cast through the distributed manager.

  In replicated ephemeral mode, `cast/3` waits for standby synchronization
  before reporting success.
  """
  @spec cast(manager(), key(), Jido.Signal.t()) :: :ok | {:error, term()}
  defdelegate cast(manager, key, signal), to: JidoCluster.InstanceManager

  @doc "Stops an agent by key on the node where it currently exists."
  @spec stop(manager(), key()) :: :ok | {:error, :not_found} | {:error, term()}
  defdelegate stop(manager, key), to: JidoCluster.InstanceManager

  @doc """
  Returns the current owner node for a key from the visible cluster view.

  During heal or failover this may differ from pre-partition placement until
  ownership converges.
  """
  @spec owner_node(manager(), key()) :: node()
  defdelegate owner_node(manager, key), to: JidoCluster.InstanceManager

  @doc "Returns manager counts by node and total active keys in the current cluster view."
  @spec stats(manager()) :: %{by_node: %{node() => non_neg_integer()}, total: non_neg_integer()}
  defdelegate stats(manager), to: JidoCluster.InstanceManager

  @doc false
  @spec supervisor_name(manager()) :: atom()
  defdelegate supervisor_name(manager), to: JidoCluster.InstanceManager
end
