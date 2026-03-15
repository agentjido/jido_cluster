defmodule JidoCluster.Internal.InstanceManagerConfig do
  @moduledoc false

  alias JidoCluster.Topology

  @cluster_defaults %{
    partition_policy: :freeze,
    min_quorum_nodes: 1,
    handoff_mode: :hibernate_thaw,
    coordination_backend: :connected_beam
  }

  @doc false
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(manager) do
    case :persistent_term.get({Jido.Agent.InstanceManager, manager}, :undefined) do
      :undefined -> :error
      config when is_map(config) -> {:ok, config}
      _other -> :error
    end
  rescue
    _ -> :error
  end

  @doc false
  @spec fetch_storage(term()) :: {module(), keyword()} | nil | :error
  def fetch_storage(manager) do
    with {:ok, config} <- fetch(manager) do
      Map.get(config, :storage)
    end
  end

  @doc false
  @spec put_cluster(term(), map()) :: :ok
  def put_cluster(manager, config) when is_map(config) do
    :persistent_term.put({JidoCluster.InstanceManager, manager}, Map.merge(@cluster_defaults, config))
  end

  @doc false
  @spec delete_cluster(term()) :: :ok
  def delete_cluster(manager) do
    :persistent_term.erase({JidoCluster.InstanceManager, manager})
    :ok
  end

  @doc false
  @spec fetch_cluster(term()) :: {:ok, map()} | :error
  def fetch_cluster(manager) do
    case :persistent_term.get({JidoCluster.InstanceManager, manager}, :undefined) do
      :undefined -> :error
      config when is_map(config) -> {:ok, Map.merge(@cluster_defaults, config)}
      _other -> :error
    end
  rescue
    _ -> :error
  end

  @doc false
  @spec cluster_available?(term(), [node()]) :: boolean()
  def cluster_available?(manager, nodes \\ Topology.connected_nodes()) when is_list(nodes) do
    case fetch_cluster(manager) do
      {:ok, %{coordination_backend: :connected_beam, partition_policy: :freeze, min_quorum_nodes: min_quorum_nodes}} ->
        Topology.quorum_met?(min_quorum_nodes, nodes)

      {:ok, _config} ->
        true

      :error ->
        true
    end
  end
end
