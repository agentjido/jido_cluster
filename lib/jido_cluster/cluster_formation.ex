defmodule JidoCluster.ClusterFormation do
  @moduledoc """
  Optional cluster formation supervisor.

  Supports both:

  - `libcluster` (`Cluster.Supervisor`) with explicit topologies
  - `dns_cluster` (`DNSCluster`) for DNS-based peer discovery
  """

  use Supervisor

  require Logger

  @doc "Child specification for optional cluster formation services."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @doc "Starts the cluster-formation supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    children = []

    children = maybe_add_libcluster(children, opts)
    children = maybe_add_dns_cluster(children, opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_add_libcluster(children, opts) do
    topologies = Keyword.get(opts, :libcluster_topologies)

    cond do
      is_nil(topologies) ->
        children

      Code.ensure_loaded?(Cluster.Supervisor) ->
        sup_name = Keyword.get(opts, :libcluster_name, JidoCluster.ClusterSupervisor)
        [{Cluster.Supervisor, [topologies, [name: sup_name]]} | children]

      true ->
        Logger.warning("JidoCluster.ClusterFormation received :libcluster_topologies but libcluster is not available")

        children
    end
  end

  defp maybe_add_dns_cluster(children, opts) do
    dns_opts = Keyword.get(opts, :dns_cluster)

    cond do
      is_nil(dns_opts) ->
        children

      not Code.ensure_loaded?(DNSCluster) ->
        Logger.warning("JidoCluster.ClusterFormation received :dns_cluster config but dns_cluster is not available")

        children

      true ->
        dns_opts = normalize_dns_opts(dns_opts)
        [{DNSCluster, dns_opts} | children]
    end
  end

  defp normalize_dns_opts(query) when is_binary(query), do: [query: query]
  defp normalize_dns_opts(opts) when is_list(opts), do: opts
end
