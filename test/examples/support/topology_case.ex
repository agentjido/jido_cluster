defmodule JidoCluster.Examples.Support.TopologyCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  alias Jido.Topology.Controller
  alias JidoCluster.Examples.Support.Definition

  defmacro __using__(_opts) do
    quote do
      use JidoCluster.Test.ClusterCase, tag: :example
      import JidoCluster.Examples.Support.TopologyCase
      alias Jido.Cluster.Examples.Topologies.Counter
      alias Jido.Cluster.Placement
      alias Jido.Topology.Controller
      setup :setup_topology
    end
  end

  def setup_topology(%{cluster: cluster}) do
    unique = System.unique_integer([:positive])
    jido = :"topology_examples_#{unique}"
    namespace = "examples/topology/#{unique}"
    table = shared_table(cluster, cluster.nodes)

    for worker <- cluster.nodes do
      assert {:ok, _} =
               cluster_call(cluster, worker, DynamicSupervisor, :start_child, [
                 Jido.Cluster.ManagerSupervisor,
                 {Jido, [name: jido, namespace: namespace, persistence: {Jido.Cluster.Storage.Mnesia, table: table}]}
               ])
    end

    {:ok, jido: jido, id: "topology-#{unique}", namespace: namespace}
  end

  def start_topology(context, module, placements) do
    first = hd(context.cluster.nodes)
    assert {:ok, instance} = cluster_call(context.cluster, first, Definition, :build, [module, context.id, placements])

    assert {:ok, controller} =
             cluster_call(context.cluster, first, DynamicSupervisor, :start_child, [
               Jido.Cluster.ManagerSupervisor,
               {Controller, jido: context.jido, topology: instance, repair: :manual}
             ])

    await_topology(context, controller)
    {controller, instance}
  end

  def await_topology(context, controller) do
    first = hd(context.cluster.nodes)

    try do
      assert :ok = cluster_call(context.cluster, first, Controller, :await_ready, [controller, 3_000])
    catch
      :exit, reason ->
        status = cluster_call(context.cluster, first, Controller, :status, [controller])
        flunk("Topology readiness failed: #{inspect(reason)}; status: #{inspect(status, limit: :infinity)}")
    end
  end

  def stop_topology(context, controller) do
    cluster_call(
      context.cluster,
      hd(context.cluster.nodes),
      __MODULE__,
      :stop_and_wait,
      [controller, context.id],
      15_000
    )
  end

  def stop_and_wait(controller, id) do
    handler = {__MODULE__, make_ref()}
    event = [:jido, :topology, :ownership, :settled]
    :ok = :telemetry.attach(handler, event, &__MODULE__.notify/4, {self(), id})

    try do
      :ok = DynamicSupervisor.terminate_child(Jido.Cluster.ManagerSupervisor, controller)

      receive do
        {:topology_settled, ^id} -> :ok
      after
        10_000 -> raise "Topology cleanup did not settle"
      end
    after
      :telemetry.detach(handler)
    end
  end

  def notify(_event, _measurements, %{topology_id: id}, {receiver, id}),
    do: send(receiver, {:topology_settled, id})

  def notify(_event, _measurements, _metadata, _config), do: :ok

  def inventory(worker, labels \\ []), do: [%{node: worker, labels: labels, available: true}]
end
