defmodule JidoCluster.Distributed.InstanceTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster
  alias JidoCluster.Test.Instance
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  setup %{cluster: cluster} do
    jido = __MODULE__.Core
    namespace = "peer-instance/#{System.unique_integer([:positive])}"

    for host <- cluster.nodes do
      assert {:ok, _} =
               cluster_call(cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Jido, name: jido, namespace: namespace}
               ])
    end

    %{jido: jido, namespace: namespace}
  end

  test "connected control nodes cannot own the same scope twice", c do
    opts = [jido: c.jido, journal: :memory]
    parent = self()

    tasks =
      for host <- c.cluster.nodes do
        Task.async(fn ->
          send(parent, {:waiting, self()})

          receive do
            :go -> :ok
          after
            5_000 -> raise "start barrier timed out"
          end

          cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [
            JidoCluster.Test.Supervisor,
            {Instance, opts}
          ])
        end)
      end

    for _ <- tasks do
      assert_receive {:waiting, pid}
      send(pid, :go)
    end

    results = Task.await_many(tasks, 10_000)
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [{:error, {:shutdown, {:failed_to_start_child, Cluster.Instance.Service, {:scope_already_owned, _}}}}] =
             Enum.filter(results, &match?({:error, _}, &1))

    assert :ok =
             cluster_call(c.cluster, node(winner), DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               winner
             ])

    for host <- c.cluster.nodes do
      assert is_pid(cluster_call(c.cluster, host, Process, :whereis, [c.jido]))

      assert %{active: 0} =
               cluster_call(c.cluster, host, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(c.jido)])
    end
  end

  for cause <- [:service, :core] do
    @tag cause: cause
    test "#{cause} loss settles remote cleanup without reactivation", c do
      [control, worker] = c.cluster.nodes

      assert {:ok, _} =
               cluster_call(c.cluster, worker, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Cluster.HostRuntime, jido: c.jido}
               ])

      hosts = [%{node: worker, labels: ["compute"], capacity: 1, available: true}]

      assert {:ok, instance} =
               cluster_call(c.cluster, control, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Instance, jido: c.jido, journal: :memory, pools: [workers: [hosts: hosts]]}
               ])

      api = fn function, args -> cluster_call(c.cluster, control, Cluster, function, [Instance | args]) end
      token = api.(:request_id, [])
      {:ok, operation} = api.(:deploy, [RequirementScheduling.new!(id: "crash"), [request_id: token]])
      assert {:ok, %{phase: :completed}} = api.(:await, [operation.id, 5_000])
      {:ok, ref} = api.(:ref, ["crash", :worker])
      {:ok, %{pid: agent}} = api.(:lookup, [ref])
      service = cluster_call(c.cluster, control, Process, :whereis, [Cluster.Instance.name(Instance, Service)])

      if c.cause == :service do
        assert true = cluster_call(c.cluster, control, Process, :exit, [service, :kill])
      else
        core = cluster_call(c.cluster, control, Process, :whereis, [c.jido])

        assert :ok =
                 cluster_call(c.cluster, control, DynamicSupervisor, :terminate_child, [
                   JidoCluster.Test.Supervisor,
                   core
                 ])
      end

      # Core loss can remove core's cleanup observer. The owner then retains
      # uncertainty until its bounded shutdown ends; it must not report success.
      eventually(fn -> not cluster_call(c.cluster, worker, Process, :alive?, [agent]) end, timeout: 8_000)
      eventually(fn -> not cluster_call(c.cluster, control, Process, :alive?, [instance]) end, timeout: 20_000)
      if c.cause == :service, do: assert(is_pid(cluster_call(c.cluster, control, Process, :whereis, [c.jido])))

      assert %{control: :reconcile} =
               cluster_call(c.cluster, worker, Cluster.HostRuntime, :status, [Cluster.HostRuntime.name(c.jido)])
    end
  end
end
