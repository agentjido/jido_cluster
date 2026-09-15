defmodule JidoCluster.Examples.Support.PlacementCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually

  defmacro __using__(_opts) do
    quote do
      # Reuse the isolated connected peers, but tag this as an example rather
      # than :peer. The normal unit run excludes the whole example learning path.
      use JidoCluster.Test.ClusterCase, tag: :example
      import JidoCluster.Examples.Support.PlacementCase
      alias Jido.Cluster.Examples.Placement.Worker
      setup :setup_placement
    end
  end

  def setup_placement(%{cluster: cluster}) do
    # Isolate each case's names and persistence table. Across hosts in one case,
    # the same Jido name and namespace make Agent identity and services compatible.
    unique = System.unique_integer([:positive])
    jido = :"placement_examples_#{unique}"
    namespace = "examples/placement/#{unique}"

    # Replicated RAM lets a moved worker restore its checkpoint while a replica
    # stays alive. It is not a durable storage service after all peers stop.
    table = shared_table(cluster, cluster.nodes)

    # Start the matching Jido service on every peer before submitting placement,
    # including spare hosts that a scenario may add to inventory later.
    for host <- cluster.nodes do
      assert {:ok, _} =
               cluster_call(cluster, host, DynamicSupervisor, :start_child, [
                 Jido.Cluster.ManagerSupervisor,
                 {Jido, name: jido, namespace: namespace, persistence: {Jido.Cluster.Storage.Mnesia, table: table}}
               ])
    end

    {:ok, jido: jido, id: "placement-#{unique}", namespace: namespace}
  end

  # A slot admits one root singleton for this Scheduler. These fixture defaults
  # make a host eligible for one compute worker; scenarios override them as needed.
  def host(worker, labels \\ ["compute"], capacity \\ 1),
    do: %{node: worker, labels: labels, capacity: capacity, available: true}

  # Pass the original Topology and configured inventory to the runtime. Unlike
  # TopologyCase, this fixture does not rewrite worker nodes in the definition.
  def scheduler_opts(c, module, hosts),
    do: [jido: c.jido, topology: module.new!(id: c.id), hosts: hosts, poll_interval: 50]

  def start_scheduler(c, module, hosts, control \\ nil) do
    # Start supervision on the requested control host. Returning a Scheduler PID
    # means the coordinator started, not that its workers are already ready.
    assert {:ok, scheduler} =
             cluster_call(c.cluster, control || hd(c.cluster.nodes), DynamicSupervisor, :start_child, [
               Jido.Cluster.ManagerSupervisor,
               {Jido.Cluster.Scheduler, scheduler_opts(c, module, hosts)}
             ])

    scheduler
  end

  # Calls follow the Scheduler's actual host. Coordinator replacement examples
  # can move control to a different peer while retaining the same test context.
  def scheduler_call(c, scheduler, function, args \\ []),
    do: cluster_call(c.cluster, node(scheduler), Jido.Cluster.Scheduler, function, [scheduler | args])

  def ready(c, scheduler) do
    # Placement and drain requests acknowledge submission before work completes.
    # Use public status as the completion barrier rather than a fixed sleep.
    eventually(fn -> scheduler_call(c, scheduler, :status).status == :ready end, timeout: 8_000)
    scheduler_call(c, scheduler, :status)
  end

  def stop_scheduler(c, scheduler) do
    # stop waits for owned core resource cleanup. Tests then check their worker
    # PIDs; ClusterCase separately checks peer processes during final cleanup.
    assert :ok = scheduler_call(c, scheduler, :stop)
    refute cluster_call(c.cluster, node(scheduler), Process, :alive?, [scheduler])
  end
end
