defmodule JidoCluster.Examples.Support.TopologyCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  alias Jido.Topology.Controller
  alias JidoCluster.Examples.Support.Definition

  defmacro __using__(_opts) do
    quote do
      # ClusterCase starts connected loopback peers and checks their exit. Use
      # only :example so the normal unit run excludes these example tests.
      use JidoCluster.Test.ClusterCase, tag: :example
      import JidoCluster.Examples.Support.TopologyCase
      alias Jido.Cluster.Examples.Topologies.Counter
      alias Jido.Cluster.Placement
      alias Jido.Topology.Controller
      setup :setup_topology
    end
  end

  def setup_topology(%{cluster: cluster}) do
    # Each case has isolated service names and identity. Within that case, all
    # peers must use the same Jido name and namespace for remote activation.
    unique = System.unique_integer([:positive])
    jido = :"topology_examples_#{unique}"
    namespace = "examples/topology/#{unique}"

    # Shared RAM checkpoints survive one host exit while another replica lives.
    # This fixture does not provide persistence after every peer has stopped.
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

    # Core runs the Controller on first. Definition.build supplies the exact
    # worker nodes chosen by the test; this helper does not run a Scheduler.
    assert {:ok, instance} = cluster_call(context.cluster, first, Definition, :build, [module, context.id, placements])

    # Manual repair leaves later move and recovery decisions with the test.
    # Core still owns initial activation, checkpoint restore, and resource cleanup.
    assert {:ok, controller} =
             cluster_call(context.cluster, first, DynamicSupervisor, :start_child, [
               Jido.Cluster.ManagerSupervisor,
               {Controller, jido: context.jido, topology: instance, repair: :manual}
             ])

    # A successful child start returns before activation completes.
    await_topology(context, controller)
    {controller, instance}
  end

  def await_topology(context, controller) do
    first = hd(context.cluster.nodes)

    # Wait on core's complete readiness result. Report its public status if the
    # bounded wait fails, so a node failure is not hidden by a generic timeout.
    try do
      assert :ok = cluster_call(context.cluster, first, Controller, :await_ready, [controller, 3_000])
    catch
      :exit, reason ->
        status = cluster_call(context.cluster, first, Controller, :status, [controller])
        flunk("Topology readiness failed: #{inspect(reason)}; status: #{inspect(status, limit: :infinity)}")
    end
  end

  def stop_topology(context, controller) do
    # Telemetry is local to the emitting BEAM. Run the cleanup listener on the
    # control node, where the Controller and its ownership watcher run.
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

    # Attach before stopping to avoid missing a fast cleanup event. Controller
    # exit alone does not prove that its separate ownership watcher has finished.
    :ok = :telemetry.attach(handler, event, &__MODULE__.notify/4, {self(), id})

    try do
      :ok = DynamicSupervisor.terminate_child(Jido.Cluster.ManagerSupervisor, controller)

      receive do
        {:topology_settled, ^id} -> :ok
      after
        10_000 -> raise "Topology cleanup did not settle"
      end
    after
      # Remove the listener on success or failure so later cases cannot reuse it.
      :telemetry.detach(handler)
    end
  end

  # Each case uses a unique Topology ID. Convert its public cleanup event into
  # the bounded receive barrier above and ignore unrelated topology events.
  def notify(_event, _measurements, %{topology_id: id}, {receiver, id}),
    do: send(receiver, {:topology_settled, id})

  def notify(_event, _measurements, _metadata, _config), do: :ok

  def inventory(worker, labels \\ []), do: [%{node: worker, labels: labels, available: true}]
end
