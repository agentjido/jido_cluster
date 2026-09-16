defmodule JidoCluster.Distributed.IndependentProgressTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster
  alias JidoCluster.Test.{Instance, MovementBarrier}
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  @tag cluster_nodes: 4
  test "an uncertain drain retains both claims while a separate host completes work", %{cluster: cluster} do
    exercise(cluster, :memory)
  end

  @tag cluster_nodes: 4
  test "recovery preserves uncertain movement while an independent deployment returns to ready", %{cluster: cluster} do
    exercise(cluster, :journal)
  end

  @tag cluster_nodes: 4
  test "an unavailable recorded source retains both claims after restart", %{cluster: cluster} do
    exercise(cluster, :source_loss)
  end

  defp exercise(cluster, mode) do
    [control, source, target, independent] = cluster.nodes
    jido = __MODULE__.Core
    namespace = "independent-progress"
    table = shared_table(cluster, cluster.nodes)

    for host <- cluster.nodes do
      assert {:ok, _} =
               cluster_call(cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Jido, name: jido, namespace: namespace, persistence: {Jido.Persistence.Mnesia, table: table}}
               ])
    end

    for host <- [source, target, independent] do
      assert {:ok, _} =
               cluster_call(cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Cluster.HostRuntime, jido: jido}
               ])
    end

    hosts =
      for host <- [source, target, independent],
          do: %{
            node: host,
            labels: [if(host == independent, do: "independent", else: "move")],
            capacity: 1,
            available: true
          }

    options = [jido: jido, pools: [workers: [hosts: hosts]]] ++ storage(mode, table)

    assert {:ok, instance} =
             cluster_call(cluster, control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {Instance, options}
             ])

    api = fn fun, args -> cluster_call(cluster, control, Cluster, fun, [Instance | args]) end
    # Distinct requirements leave the independent allocation free.
    topology = on_pool("move", "move")

    topology =
      Enum.find_value(1..100, fn n ->
        {:ok, candidate} = Jido.Topology.instantiate(topology.definition, id: "move-#{n}")

        case api.(:plan, [candidate]) do
          {:ok, %{placements: %{"worker" => ^source}}} -> candidate
          _ -> nil
        end
      end)

    assert topology
    {:ok, deploy} = api.(:deploy, [topology, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [deploy.id])
    {:ok, ref} = api.(:ref, [topology.id, :worker])
    {:ok, %{pid: previous}} = api.(:lookup, [ref])

    assert {:ok, _} =
             cluster_call(cluster, control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {MovementBarrier, []}
             ])

    {:ok, drain} = api.(:drain, [source, [request_id: api.(:request_id, [])]])
    eventually(fn -> cluster_call(cluster, control, GenServer, :call, [MovementBarrier, :status]) != [] end)

    assert [%{task: task, metadata: metadata}] =
             cluster_call(cluster, control, GenServer, :call, [MovementBarrier, :status])

    assert metadata.parent_operation_id == drain.id
    assert Enum.sort(Enum.map(api.(:claims, []), & &1.host)) == Enum.sort([source, target])
    refute cluster_call(cluster, source, Process, :alive?, [previous])
    assert {:ok, current} = cluster_call(cluster, target, Jido, :resolve_agent, [jido, ref])
    assert node(current) == target

    assert true = cluster_call(cluster, control, Process, :exit, [task, :kill])
    assert {:ok, %{phase: :uncertain}} = api.(:await, [drain.id])
    assert Enum.all?(api.(:claims, []), &(&1.state == :uncertain))
    assert {:error, {:resources_uncertain, _}} = api.(:drain, [source, [request_id: api.(:request_id, [])]])

    {:ok, other} = api.(:deploy, [on_pool("independent", "independent"), [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [other.id])
    {:ok, other_ref} = api.(:ref, ["independent", :worker])
    assert {:ok, %{node: ^independent}} = api.(:lookup, [other_ref])
    claims = api.(:claims, [])
    assert Enum.count(claims, &(&1.state == :uncertain)) == 2
    assert Enum.count(claims, &(&1.state == :active)) == 1

    instance =
      if mode in [:journal, :source_loss] do
        recover_independent(
          cluster,
          {control, source, target, independent},
          instance,
          options,
          api,
          {topology.id, mode},
          {ref, other_ref},
          drain.id
        )
      else
        instance
      end

    assert :ok =
             cluster_call(cluster, control, DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               instance
             ])

    check_cleanup(cluster, {source, target, independent}, jido, mode)
  end

  defp check_cleanup(cluster, {source, target, independent}, jido, mode) do
    cleanup_hosts = if mode == :source_loss, do: [target, independent], else: [source, target, independent]

    for host <- cleanup_hosts do
      assert %{active: 0} =
               cluster_call(cluster, host, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(jido)])
    end
  end

  defp recover_independent(
         cluster,
         {control, source, target, independent},
         instance,
         options,
         api,
         {topology_id, mode},
         {ref, other_ref},
         drain_id
       ) do
    interrupt_source(cluster, {control, source, target}, api, topology_id, ref, mode)

    assert :ok =
             cluster_call(cluster, control, DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               instance
             ])

    {:ok, replacement} =
      cluster_call(cluster, control, DynamicSupervisor, :start_child, [
        JidoCluster.Test.Supervisor,
        {Instance, options}
      ])

    assert %{status: :reconciliation_required} = api.(:status, [])
    assert :ok = api.(:reconcile, [])
    eventually(fn -> api.(:status, []).recovering == false end)
    assert {:ok, %{recovery: :uncertain, agent_readiness: :uncertain}} = api.(:status, [topology_id])
    assert {:ok, %{agent_readiness: :ready}} = api.(:status, ["independent"])
    assert {:ok, %{node: ^independent}} = api.(:lookup, [other_ref])
    assert {:ok, %{phase: :uncertain}} = api.(:operation, [drain_id])
    assert Enum.count(api.(:claims, []), &(&1.state == :uncertain)) == 2
    assert Enum.count(api.(:claims, []), &(&1.state == :active)) == 1

    assert %{active: 0} =
             cluster_call(cluster, target, DynamicSupervisor, :count_children, [
               Jido.agent_supervisor_name(__MODULE__.Core)
             ])

    replacement
  end

  defp interrupt_source(cluster, {control, _source, target}, api, topology_id, ref, :journal) do
    jido = __MODULE__.Core
    {:ok, %{activation: activation}} = api.(:status, [topology_id])
    {:ok, {:active, owner}} = cluster_call(cluster, control, Cluster.Activation, :inspect, [activation])
    assert true = cluster_call(cluster, control, Process, :exit, [owner, :kill])

    eventually(fn ->
      cluster_call(cluster, target, Jido, :resolve_agent, [jido, ref]) == {:error, :not_found}
    end)
  end

  defp interrupt_source(cluster, {_control, source, _target}, _api, _topology, _ref, :source_loss) do
    # Only this test knows the source exited. Recovery receives no death receipt.
    assert :ok = stop_node(cluster, source)
  end

  defp storage(:memory, _table), do: [journal: :memory]

  defp storage(mode, table) when mode in [:journal, :source_loss] do
    topology = RequirementScheduling.new!(id: "registry")

    [
      journal: {Jido.Persistence.Mnesia, table: table},
      registry: %{
        "schema/v1" => {:schema, topology.definition.schema},
        "worker/v1" => {:agent, JidoCluster.Test.PlacementWorker},
        "node" => {:atom, :node}
      }
    ]
  end

  defp on_pool(id, label) do
    topology = RequirementScheduling.new!(id: id)
    metadata = Map.put(topology.definition.metadata, "jido.cluster.requirements", %{"worker" => [label]})
    {:ok, definition} = Jido.Topology.new(%{topology.definition | metadata: metadata})
    {:ok, instance} = Jido.Topology.instantiate(definition, id: id)
    instance
  end
end
