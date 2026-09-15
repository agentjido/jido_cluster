defmodule JidoCluster.Application do
  # covers: jido_cluster.bootstrap.application_starts_manager_supervisor
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: JidoCluster.InstanceManager.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: JidoCluster.Supervisor)
  end
end
