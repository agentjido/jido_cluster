defmodule JidoCluster.Distributed.DataDefinedAgentTest do
  use JidoCluster.Test.ClusterCase

  alias Jido.Cluster
  alias JidoCluster.Test.{CodecRegistry, Instance, TopologyCounter}

  test "a neutral Agent definition runs on a remote Cluster host", %{cluster: cluster} do
    [control, worker] = cluster.nodes
    jido = __MODULE__.Core
    namespace = "distributed-data-defined-agent"
    topology = topology()
    table = shared_table(cluster, cluster.nodes)

    registry =
      CodecRegistry.merge([
        CodecRegistry.for_topology(topology),
        CodecRegistry.stable(Enum.map(cluster.nodes, &{:atom, &1}))
      ])

    for host <- cluster.nodes do
      assert {:ok, _core} =
               cluster_call(cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Jido,
                  name: jido,
                  namespace: namespace,
                  persistence: {Jido.Persistence.Mnesia, table: table},
                  codec_registry: registry}
               ])
    end

    assert {:ok, _runtime} =
             cluster_call(cluster, worker, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {Cluster.HostRuntime, jido: jido}
             ])

    hosts = [%{node: worker, labels: ["compute"], capacity: 1, available: true}]

    assert {:ok, instance} =
             cluster_call(cluster, control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {Instance, jido: jido, journal: :memory, registry: registry, pools: [workers: [hosts: hosts]]}
             ])

    api = fn function, args -> cluster_call(cluster, control, Cluster, function, [Instance | args]) end

    assert {:ok, operation} = api.(:deploy, [topology, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [operation.id])
    assert {:ok, ref} = api.(:ref, [topology.id, :worker])
    assert {:ok, %{node: ^worker}} = api.(:lookup, [ref])

    assert {:ok, %{state: %{count: 1}}} =
             api.(:call, [ref, TopologyCounter.increment_signal!(), 5_000])

    assert :ok =
             cluster_call(cluster, control, DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               instance
             ])

    eventually(fn -> cluster_call(cluster, worker, Jido, :agent_count, [jido]) == 0 end)
  end

  defp topology do
    definition = %{TopologyCounter.definition() | module: Jido.Agent, name: "distributed_data_counter", vsn: nil}

    topology =
      Jido.Topology.new!(%{
        name: "distributed_data_agents",
        agents: [%{key: :worker, definition: definition}],
        metadata: %{"jido.cluster.requirements" => %{"worker" => ["compute"]}}
      })

    {:ok, instance} = Jido.Topology.instantiate(topology, id: "data-defined")
    instance
  end
end
