defmodule JidoCluster.Test.DockerHost.Runtime do
  @moduledoc false
  use Supervisor
  alias Jido.Cluster.HostProvider.Step
  alias Jido.Cluster.HostRuntime
  alias Jido.Persistence.Mnesia

  @cores [
    JidoCluster.Test.DockerHost.Core,
    Jido.Cluster.Examples.AcquiredTopology.Cluster.Core,
    Jido.Cluster.Examples.LostAcquireReply.Cluster.Core,
    Jido.Cluster.Examples.BorrowedAndIncompatible.Cluster.Core,
    Jido.Cluster.Examples.ReleaseGuard.Cluster.Core,
    Jido.Cluster.Examples.AbruptDeathCleanup.Cluster.Core,
    Jido.Cluster.Examples.DeploymentLifecycle.Cluster.Core,
    Jido.Cluster.Examples.ProviderLifecycle.Cluster.Core
  ]

  def core, do: JidoCluster.Test.DockerHost.Core

  def start_link(environment) when is_map(environment) do
    # Do not retain cookies or unrelated process environment in an OTP start
    # argument. The release has already configured its distribution cookie.
    fields = [
      "JIDO_CLUSTER_HOST_STEP",
      "JIDO_CLUSTER_HOST_NODE",
      "JIDO_CLUSTER_CONTROL_NODE",
      "JIDO_CLUSTER_NAMESPACE",
      "JIDO_CLUSTER_TABLE",
      "JIDO_CLUSTER_CORE",
      "JIDO_CLUSTER_ALLOCATION",
      "JIDO_CLUSTER_CAPACITY"
    ]

    Supervisor.start_link(__MODULE__, Map.take(environment, fields), name: __MODULE__)
  end

  def start_link(_), do: {:error, :invalid_docker_host_environment}

  @impl true
  def init(environment) do
    with {:ok, config} <- config(environment),
         true <- Atom.to_string(node()) == config.node,
         true <- Node.connect(config.control),
         {:ok, persistence} <- persistence(config) do
      # Native peers already own this fixture supervisor. The prepared release
      # creates its own for worker-side test barriers; it is not an SDK service.
      fixtures =
        if Process.whereis(JidoCluster.Test.Supervisor),
          do: [],
          else: [{DynamicSupervisor, name: JidoCluster.Test.Supervisor, strategy: :one_for_one}]

      children =
        fixtures ++
          [
            {Jido, name: config.core, namespace: config.namespace, persistence: persistence},
            {HostRuntime, [jido: config.core, provider_step: config.step] ++ config.allocations}
          ]

      Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
    else
      _ -> exit(:docker_host_boot_failed)
    end
  end

  def config(environment) when is_map(environment) do
    with {:ok, step} <- step(environment["JIDO_CLUSTER_HOST_STEP"]),
         namespace = environment["JIDO_CLUSTER_NAMESPACE"] || step_namespace(step),
         true <- identifier?(namespace),
         host = environment["JIDO_CLUSTER_HOST_NODE"],
         true <- identifier?(host) and host_matches?(step, host),
         control = environment["JIDO_CLUSTER_CONTROL_NODE"],
         true <- atom_identifier?(control),
         table = environment["JIDO_CLUSTER_TABLE"],
         true <- is_nil(table) or atom_identifier?(table),
         {:ok, core} <- configured_core(environment["JIDO_CLUSTER_CORE"]),
         {:ok, allocations} <- allocations(environment) do
      # These are two bounded, trusted deployment configuration values. No node
      # or table atom is decoded from a scope journal or provider observation.
      {:ok,
       %{
         step: step,
         namespace: namespace,
         node: host,
         control: String.to_atom(control),
         table: if(table, do: String.to_atom(table)),
         core: core,
         allocations: allocations
       }}
    else
      _ -> {:error, :invalid_docker_host_environment}
    end
  end

  def config(_), do: {:error, :invalid_docker_host_environment}

  defp configured_core(nil), do: {:ok, core()}

  defp configured_core(name) do
    case Enum.find(@cores, &(Atom.to_string(&1) == name)) do
      nil -> :error
      core -> {:ok, core}
    end
  end

  defp allocations(environment) do
    case {environment["JIDO_CLUSTER_ALLOCATION"], environment["JIDO_CLUSTER_CAPACITY"]} do
      {nil, nil} -> {:ok, []}
      {id, capacity} -> allocation(id, capacity)
    end
  end

  defp allocation(id, capacity) when is_binary(id) and byte_size(id) in 1..128 and is_binary(capacity) do
    with true <- String.valid?(id),
         true <- byte_size(capacity) in 1..3,
         {number, ""} when number in 1..256 <- Integer.parse(capacity),
         true <- Integer.to_string(number) == capacity do
      {:ok, [allocations: %{id => number}]}
    else
      _ -> :error
    end
  end

  defp allocation(_, _), do: :error
  defp identifier?(value), do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)
  defp atom_identifier?(value), do: identifier?(value) and byte_size(value) <= 255
  defp step(nil), do: {:ok, nil}

  defp step(bytes) when is_binary(bytes) and byte_size(bytes) <= 8_192 do
    with {:ok, record} <- Jason.decode(bytes), {:ok, _} <- Step.from_record(record), do: {:ok, record}
  end

  defp step(_), do: :error
  defp step_namespace(nil), do: nil
  defp step_namespace(step), do: step["namespace"]
  defp host_matches?(nil, _), do: true
  defp host_matches?(step, host), do: step["host"] == host
  defp persistence(%{table: nil}), do: {:ok, nil}

  defp persistence(config) do
    with {:ok, _} <- :mnesia.change_config(:extra_db_nodes, [config.control]),
         :ok <- :mnesia.wait_for_tables([config.table], 5_000),
         :ok <- Mnesia.validate_options(table: config.table),
         do: {:ok, {Mnesia, table: config.table}}
  end
end
