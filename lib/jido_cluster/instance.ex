defmodule Jido.Cluster.Instance do
  @moduledoc "Owns a named Cluster service and, in managed mode, its core instance."
  use Supervisor

  alias Jido.Cluster.Instance.{Config, Service}

  @doc "Starts the instance after configuration validation."
  @spec start_link(Config.t()) :: Supervisor.on_start()
  def start_link(%Config{} = config) do
    if config.mode == :managed and Process.whereis(config.jido) do
      {:error, :managed_core_already_started}
    else
      Supervisor.start_link(__MODULE__, config, name: config.name)
    end
  end

  @doc "Returns a stable local name for an instance-owned service."
  @spec name(atom(), atom()) :: atom()
  def name(instance, service), do: Module.concat(instance, service)

  @impl true
  def init(config) do
    core =
      if config.mode == :managed do
        [{Jido, name: config.jido, namespace: config.namespace, persistence: config.agent_persistence}]
      else
        []
      end

    children =
      core ++
        [
          %{id: Jido.Cluster.HostRuntime, start: {Jido.Cluster.HostRuntime, :attach, [[jido: config.jido]]}},
          {Registry, keys: :unique, name: name(config.name, Registry)},
          {DynamicSupervisor, strategy: :one_for_one, name: name(config.name, Deployments)},
          {Task.Supervisor, name: name(config.name, Operations)},
          {Service, config}
        ]

    # Loss of an authority stops the whole boundary. Durable intent remains in
    # the journal for an explicit restart and cleanup reconciliation.
    # Core is first, so it outlives dependent shutdown and confirmed cleanup.
    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end
end
