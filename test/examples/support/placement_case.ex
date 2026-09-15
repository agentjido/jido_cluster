defmodule JidoCluster.Examples.Support.PlacementCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually

  defmacro __using__(_opts) do
    quote do
      use JidoCluster.Test.ClusterCase, tag: :example
      import JidoCluster.Examples.Support.PlacementCase
      alias Jido.Cluster.Examples.Placement.Worker
      setup :setup_placement
    end
  end

  def setup_placement(%{cluster: cluster}) do
    unique = System.unique_integer([:positive])
    jido = :"placement_examples_#{unique}"
    namespace = "examples/placement/#{unique}"
    table = shared_table(cluster, cluster.nodes)

    for host <- cluster.nodes do
      assert {:ok, _} =
               cluster_call(cluster, host, DynamicSupervisor, :start_child, [
                 Jido.Cluster.ManagerSupervisor,
                 {Jido, name: jido, namespace: namespace, persistence: {Jido.Cluster.Storage.Mnesia, table: table}}
               ])
    end

    {:ok, jido: jido, id: "placement-#{unique}", namespace: namespace}
  end

  def host(worker, labels \\ ["compute"], capacity \\ 1),
    do: %{node: worker, labels: labels, capacity: capacity, available: true}

  def scheduler_opts(c, module, hosts),
    do: [jido: c.jido, topology: module.new!(id: c.id), hosts: hosts, poll_interval: 50]

  def start_scheduler(c, module, hosts, control \\ nil) do
    assert {:ok, scheduler} =
             cluster_call(c.cluster, control || hd(c.cluster.nodes), DynamicSupervisor, :start_child, [
               Jido.Cluster.ManagerSupervisor,
               {Jido.Cluster.Scheduler, scheduler_opts(c, module, hosts)}
             ])

    scheduler
  end

  def scheduler_call(c, scheduler, function, args \\ []),
    do: cluster_call(c.cluster, node(scheduler), Jido.Cluster.Scheduler, function, [scheduler | args])

  def ready(c, scheduler) do
    eventually(fn -> scheduler_call(c, scheduler, :status).status == :ready end, timeout: 8_000)
    scheduler_call(c, scheduler, :status)
  end

  def stop_scheduler(c, scheduler) do
    assert :ok = scheduler_call(c, scheduler, :stop)
    refute cluster_call(c.cluster, node(scheduler), Process, :alive?, [scheduler])
  end
end
