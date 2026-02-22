defmodule Jido.Cluster.InstanceManager do
  @moduledoc """
  Distributed wrapper around `Jido.Agent.InstanceManager`.

  Preferred public namespace for keyed agent management across connected nodes.
  Delegates to `JidoCluster.InstanceManager`.
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

  @doc "Gets or starts an agent by key on the owner node."
  @spec get(manager(), key(), keyword()) :: {:ok, pid()} | {:error, term()}
  defdelegate get(manager, key, opts \\ []), to: JidoCluster.InstanceManager

  @doc "Looks up an existing agent by key on the owner node."
  @spec lookup(manager(), key()) :: {:ok, pid()} | :error
  defdelegate lookup(manager, key), to: JidoCluster.InstanceManager

  @doc "Routes a synchronous signal call through the distributed manager."
  @spec call(manager(), key(), Jido.Signal.t(), timeout()) :: {:ok, struct()} | {:error, term()}
  defdelegate call(manager, key, signal, timeout \\ 5_000), to: JidoCluster.InstanceManager

  @doc "Routes an asynchronous signal cast through the distributed manager."
  @spec cast(manager(), key(), Jido.Signal.t()) :: :ok | {:error, term()}
  defdelegate cast(manager, key, signal), to: JidoCluster.InstanceManager

  @doc "Stops an agent by key on the node where it currently exists."
  @spec stop(manager(), key()) :: :ok | {:error, :not_found} | {:error, term()}
  defdelegate stop(manager, key), to: JidoCluster.InstanceManager

  @doc "Returns the deterministic owner node for a key."
  @spec owner_node(manager(), key()) :: node()
  defdelegate owner_node(manager, key), to: JidoCluster.InstanceManager

  @doc "Returns manager counts by node and total active keys in cluster view."
  @spec stats(manager()) :: %{by_node: %{node() => non_neg_integer()}, total: non_neg_integer()}
  defdelegate stats(manager), to: JidoCluster.InstanceManager

  @doc false
  @spec supervisor_name(manager()) :: atom()
  defdelegate supervisor_name(manager), to: JidoCluster.InstanceManager
end
