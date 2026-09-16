defmodule JidoCluster.Examples.Support.SharedCapacityCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase

  def start(c, topology, inventories) do
    [control | workers] = c.cluster.nodes
    assert length(workers) == length(inventories)
    service = Module.concat(topology, Cluster)
    jido = Module.concat(service, Core)
    namespace = "shared-capacity/#{System.unique_integer([:positive])}"
    table = shared_table(c.cluster, c.cluster.nodes)

    for host <- c.cluster.nodes do
      assert {:ok, _} =
               cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Jido, name: jido, namespace: namespace, persistence: {Jido.Persistence.Mnesia, table: table}}
               ])
    end

    for host <- workers do
      assert {:ok, _} =
               cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Jido.Cluster.HostRuntime, jido: jido}
               ])
    end

    hosts =
      Enum.zip_with(workers, inventories, fn host, {labels, capacity} ->
        %{node: host, labels: labels, capacity: capacity, available: true}
      end)

    assert {:ok, instance} =
             cluster_call(c.cluster, control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {service, jido: jido, journal: :memory, pools: [workers: [hosts: hosts]]}
             ])

    Map.merge(c, %{
      control: control,
      workers: workers,
      service: service,
      jido: jido,
      namespace: namespace,
      instance: instance,
      topology_module: topology
    })
  end

  def api(c, function, args \\ []),
    do: cluster_call(c.cluster, c.control, Jido.Cluster, function, [c.service | args])

  def deploy(c, topology) do
    assert {:ok, operation} = api(c, :deploy, [topology, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])
    assert {:ok, ref} = api(c, :ref, [topology.id, :worker])
    assert {:ok, location} = api(c, :lookup, [ref])
    {ref, location.pid}
  end

  def selected_on(c, module, prefix, host) do
    Enum.find_value(1..100, fn n ->
      topology = module.new!(id: "#{prefix}-#{n}")

      case api(c, :plan, [topology]) do
        {:ok, %{placements: %{"worker" => ^host}}} -> topology
        _ -> nil
      end
    end) || raise "No topology selected the requested test source"
  end

  def stop(c, id) do
    assert {:ok, operation} = api(c, :stop, [id, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])
  end

  def count(c, pid, count) do
    assert %{agent: %{state: %{count: ^count}}} =
             cluster_call(c.cluster, node(pid), Jido.AgentServer, :snapshot, [pid])
  end

  def cleanup(c) do
    assert :ok =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               c.instance
             ])

    for host <- c.workers do
      assert %{active: 0} =
               cluster_call(c.cluster, host, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(c.jido)])
    end
  end
end
