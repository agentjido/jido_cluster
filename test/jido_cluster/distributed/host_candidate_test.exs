defmodule JidoCluster.Distributed.HostCandidateTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster
  alias JidoCluster.Test.Instance
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  for {fault, options, stage, reason} <- [
        {:release, [release: "old-release"], :probe, {:incompatible, :release}},
        {:budget, [allocations: %{"default" => 1}], :confirmation, :capacity_conflict}
      ] do
    @tag cluster_nodes: 3
    test "stale #{fault} evidence preserves the selected host reason and starts no fallback", %{cluster: cluster} do
      [control, source, other] = cluster.nodes
      jido = __MODULE__.Core

      for host <- cluster.nodes do
        assert {:ok, _} =
                 cluster_call(cluster, host, DynamicSupervisor, :start_child, [
                   JidoCluster.Test.Supervisor,
                   {Jido, name: jido, namespace: "candidate-check"}
                 ])
      end

      for host <- [source, other] do
        opts = if host == source, do: unquote(Macro.escape(options)), else: []

        assert {:ok, _} =
                 cluster_call(cluster, host, DynamicSupervisor, :start_child, [
                   JidoCluster.Test.Supervisor,
                   {Cluster.HostRuntime, Keyword.put(opts, :jido, jido)}
                 ])
      end

      hosts = for host <- [source, other], do: %{node: host, labels: ["compute"], capacity: 2, available: true}

      assert {:ok, instance} =
               cluster_call(cluster, control, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Instance, jido: jido, journal: :memory, pools: [workers: [hosts: hosts]]}
               ])

      api = fn fun, args -> cluster_call(cluster, control, Cluster, fun, [Instance | args]) end

      topology =
        Enum.find_value(1..100, fn n ->
          candidate = RequirementScheduling.new!(id: "stale-#{n}")

          case api.(:plan, [candidate]) do
            {:ok, %{placements: %{"worker" => ^source}}} -> candidate
            _ -> nil
          end
        end)

      assert topology
      token = api.(:request_id, [])
      {:ok, operation} = api.(:deploy, [topology, [request_id: token]])

      assert {:ok,
              %{
                phase: :uncertain,
                reason:
                  {:host_rejected,
                   %{host: ^source, allocation: "default", stage: unquote(stage), reason: unquote(Macro.escape(reason))}}
              }} = api.(:await, [operation.id])

      assert [%{host: ^source, state: :uncertain}] = api.(:claims, [])
      assert {:ok, %{id: id}} = api.(:deploy, [topology, [request_id: token]])
      assert id == operation.id

      for host <- [source, other] do
        assert %{active: 0} =
                 cluster_call(cluster, host, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(jido)])
      end

      assert :ok =
               cluster_call(cluster, control, DynamicSupervisor, :terminate_child, [
                 JidoCluster.Test.Supervisor,
                 instance
               ])
    end
  end
end
