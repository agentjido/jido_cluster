defmodule JidoCluster.Internal.InstanceManagerConfig do
  @moduledoc false

  alias Jido.Cluster.Config
  alias JidoCluster.Topology

  defp config_key(manager), do: {JidoCluster.InstanceManager, :config, manager}

  defp default_config(manager), do: Config.new!(name: manager)

  @doc false
  @spec fetch(term()) :: {:ok, Config.t()} | :error
  def fetch(manager) do
    case :persistent_term.get(config_key(manager), :undefined) do
      :undefined -> :error
      %Config{} = config -> {:ok, config}
      _other -> :error
    end
  rescue
    _ -> :error
  end

  @doc false
  @spec fetch_storage(term()) :: {module(), keyword()} | nil | :error
  def fetch_storage(manager) do
    with {:ok, %Config{} = config} <- fetch(manager) do
      Map.get(config, :storage)
    end
  end

  @doc false
  @spec put_manager(term(), map()) :: :ok
  def put_manager(manager, config) when is_map(config) do
    merged =
      manager
      |> current_or_default()
      |> Config.merge(Map.put(config, :name, manager))

    :persistent_term.put(config_key(manager), merged)
  end

  @doc false
  @spec delete_manager(term()) :: :ok
  def delete_manager(manager) do
    :persistent_term.erase(config_key(manager))
    :ok
  end

  @doc false
  @spec put_cluster(term(), map()) :: :ok
  def put_cluster(manager, config) when is_map(config) do
    merged =
      manager
      |> current_or_default()
      |> Config.merge(Map.put(config, :name, manager))

    :persistent_term.put(config_key(manager), merged)
  end

  @doc false
  @spec delete_cluster(term()) :: :ok
  def delete_cluster(manager) do
    :persistent_term.erase(config_key(manager))
    :ok
  end

  @doc false
  @spec fetch_cluster(term()) :: {:ok, Config.t()} | :error
  def fetch_cluster(manager) do
    fetch(manager)
  end

  @doc false
  @spec cluster_available?(term(), [node()]) :: boolean()
  def cluster_available?(manager, nodes \\ Topology.connected_nodes()) when is_list(nodes) do
    case fetch_cluster(manager) do
      {:ok,
       %Config{coordination_backend: :connected_beam, partition_policy: :freeze, min_quorum_nodes: min_quorum_nodes}} ->
        Topology.quorum_met?(min_quorum_nodes, nodes)

      {:ok, %Config{}} ->
        true

      :error ->
        true
    end
  end

  defp current_or_default(manager) do
    case fetch(manager) do
      {:ok, %Config{} = config} -> config
      :error -> default_config(manager)
    end
  end
end
