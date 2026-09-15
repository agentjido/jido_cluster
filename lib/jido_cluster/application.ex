defmodule JidoCluster.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      %{id: Jido.Cluster.PG, start: {:pg, :start_link, [Jido.Cluster.PG]}},
      {DynamicSupervisor, name: Jido.Cluster.OwnerSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Jido.Cluster.ManagerSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: JidoCluster.Supervisor)
  end
end
