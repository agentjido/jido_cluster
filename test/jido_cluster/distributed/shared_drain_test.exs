defmodule JidoCluster.Distributed.SharedDrainTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster
  alias JidoCluster.Test.{Instance, MovementBarrier}
  alias JidoCluster.Test.PlacementWorker, as: Worker
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  @tag cluster_nodes: 3
  test "drain reserves both moves and preserves Refs and committed state", %{cluster: cluster} do
    exercise(cluster, :memory)
  end

  @tag cluster_nodes: 3
  test "durable drain records both moves and preserves Refs and committed state", %{cluster: cluster} do
    exercise(cluster, :journal)
  end

  @tag cluster_nodes: 3
  test "partial drain survives abrupt coordinator loss with the original request", %{cluster: cluster} do
    exercise(cluster, :recovery)
  end

  @tag cluster_nodes: 3
  test "recovery retains the source reservation for a move that has not started", %{cluster: cluster} do
    exercise(cluster, :early_recovery)
  end

  @tag cluster_nodes: 3
  test "journal durability alone cannot authorize restore of a moved core target", %{cluster: cluster} do
    exercise(cluster, :volatile_recovery)
  end

  defp exercise(cluster, mode) do
    [control, source, target] = cluster.nodes
    namespace = "shared-drain/#{System.unique_integer([:positive])}"
    jido = __MODULE__.Core
    table = shared_table(cluster, cluster.nodes)
    persistence = if mode == :volatile_recovery, do: nil, else: {Jido.Persistence.Mnesia, table: table}

    for host <- cluster.nodes do
      assert {:ok, _} =
               cluster_call(cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Jido, name: jido, namespace: namespace, persistence: persistence}
               ])
    end

    for host <- [source, target] do
      assert {:ok, _} =
               cluster_call(cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Cluster.HostRuntime, jido: jido}
               ])
    end

    hosts = for host <- [source, target], do: %{node: host, labels: ["compute"], capacity: 2, available: true}
    storage = storage(mode, table)
    options = [jido: jido, pools: [workers: [hosts: hosts]]] ++ storage

    assert {:ok, instance} =
             cluster_call(cluster, control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {Instance, options}
             ])

    api = fn function, args -> cluster_call(cluster, control, Cluster, function, [Instance | args]) end

    refs = deploy_workers(api, source)

    assert Enum.all?(api.(:claims, []), &(&1.host == source))
    barrier = if mode in [:recovery, :early_recovery], do: start_barrier(cluster, control)
    token = api.(:request_id, [])
    assert {:ok, drain} = api.(:drain, [source, [request_id: token]])
    assert map_size(drain.steps) == 2

    check_steps(drain, source, target)

    instance =
      if barrier do
        recover_drain(cluster, control, instance, barrier, api, drain, mode)
      else
        instance
      end

    result = api.(:await, [drain.id, 10_000])

    assert match?({:ok, %{phase: :completed}}, result),
           inspect({result, Enum.map(Map.keys(drain.steps), &api.(:status, [&1]))})

    assert {:ok, %{id: same}} = api.(:drain, [source, [request_id: token]])
    assert same == drain.id
    assert length(api.(:claims, [])) == 2
    assert Enum.all?(api.(:claims, []), &(&1.host == target and &1.state == :active))

    check_workers(cluster, api, refs, source, target, mode)

    assert {:error, {:no_capacity, "worker"}} = api.(:plan, [RequirementScheduling.new!(id: "excluded")])

    assert :ok =
             cluster_call(cluster, control, DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               instance
             ])

    if mode == :volatile_recovery, do: check_volatile_recovery(cluster, control, options, api, drain)

    assert %{active: 0} =
             cluster_call(cluster, target, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(jido)])
  end

  defp check_workers(cluster, api, refs, source, target, mode) do
    for {ref, previous, count} <- refs do
      count = if mode == :volatile_recovery, do: 0, else: count
      {:ok, %{pid: current}} = api.(:lookup, [ref])
      assert node(current) == target
      refute cluster_call(cluster, source, Process, :alive?, [previous])

      assert %{agent: %{state: %{count: ^count}}} =
               cluster_call(cluster, target, Jido.AgentServer, :snapshot, [current])
    end
  end

  defp deploy_workers(api, source) do
    for count <- 1..2 do
      topology = choose(api, source, count)

      assert topology
      {:ok, op} = api.(:deploy, [topology, [request_id: api.(:request_id, [])]])
      assert {:ok, %{phase: :completed}} = api.(:await, [op.id, 5_000])
      {:ok, ref} = api.(:ref, [topology.id, :worker])
      for _ <- 1..count, do: assert({:ok, _} = api.(:call, [ref, Worker.work_signal!()]))
      {:ok, %{pid: pid}} = api.(:lookup, [ref])
      {ref, pid, count}
    end
  end

  defp choose(api, source, count) do
    Enum.find_value(1..100, fn n ->
      candidate = RequirementScheduling.new!(id: "work-#{count}-#{n}")

      case api.(:plan, [candidate]) do
        {:ok, %{placements: %{"worker" => ^source}}} -> candidate
        _ -> nil
      end
    end)
  end

  defp check_steps(drain, source, target) do
    for {_id, step} <- drain.steps do
      assert step.selected == %{"worker" => target}
      assert step.arrivals == step.selected
      assert [{_ref, ^source}] = Map.to_list(step.retired)
    end
  end

  defp storage(:memory, _table), do: [journal: :memory]

  defp storage(mode, table) when mode in [:journal, :recovery, :early_recovery, :volatile_recovery] do
    topology = RequirementScheduling.new!(id: "registry")

    [
      journal: {Jido.Persistence.Mnesia, table: table},
      registry: %{
        "schema/v1" => {:schema, topology.definition.schema},
        "worker/v1" => {:agent, Worker},
        "node" => {:atom, :node}
      }
    ]
  end

  defp check_volatile_recovery(cluster, control, options, api, drain) do
    child = {Instance, options}

    {:ok, replacement} =
      cluster_call(cluster, control, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, child])

    assert :ok = api.(:reconcile, [])
    eventually(fn -> api.(:status, []).recovering == false end)

    for id <- Map.keys(drain.steps) do
      assert {:ok, %{agent_readiness: :uncertain, reason: :placement_restore_requires_persistence}} =
               api.(:status, [id])
    end

    assert Enum.all?(api.(:claims, []), &(&1.state == :uncertain))

    assert :ok =
             cluster_call(cluster, control, DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               replacement
             ])
  end

  defp start_barrier(cluster, control) do
    {:ok, barrier} =
      cluster_call(cluster, control, DynamicSupervisor, :start_child, [
        JidoCluster.Test.Supervisor,
        {MovementBarrier, []}
      ])

    barrier
  end

  defp recover_drain(cluster, control, instance, barrier, api, drain, mode) do
    waiting = fn -> cluster_call(cluster, control, GenServer, :call, [MovementBarrier, :status]) end
    eventually(fn -> waiting.() != [] end)

    completed =
      if mode == :recovery do
        assert :ok = cluster_call(cluster, control, GenServer, :call, [MovementBarrier, :release])
        eventually(fn -> waiting.() != [] end)
        1
      else
        0
      end

    {:ok, partial} = api.(:operation, [drain.id])
    assert Enum.count(partial.steps, fn {_, step} -> step.phase == :completed end) == completed
    assert length(api.(:claims, [])) == 4 - completed
    service = Cluster.Instance.name(Instance, Service)
    pid = cluster_call(cluster, control, Process, :whereis, [service])
    assert true = cluster_call(cluster, control, Process, :exit, [pid, :kill])
    eventually(fn -> not cluster_call(cluster, control, Process, :alive?, [instance]) end)

    assert :ok =
             cluster_call(cluster, control, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, barrier])

    eventually(fn -> is_pid(cluster_call(cluster, control, Process, :whereis, [Instance])) end)
    replacement = cluster_call(cluster, control, Process, :whereis, [Instance])
    assert replacement != instance

    assert %{status: :reconciliation_required} = api.(:status, [])
    assert {:ok, restored} = api.(:operation, [drain.id])
    assert restored.steps == partial.steps
    assert :ok = api.(:reconcile, [])
    replacement
  end
end
