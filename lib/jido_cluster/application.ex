defmodule JidoCluster.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Jido.Cluster.Activation,
      {Registry, name: Jido.Cluster.FederationRegistry, keys: :unique},
      {DynamicSupervisor, name: Jido.Cluster.FederationSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Jido.Cluster.OwnerSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Jido.Cluster.HostSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: JidoCluster.Supervisor)
  end
end
