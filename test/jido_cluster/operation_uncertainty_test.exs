defmodule JidoCluster.OperationUncertaintyTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster
  alias JidoCluster.Test.OperationBarrier
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "lost-operation-result"
  end

  test "a lost completion response retains claims and cannot start another Agent" do
    hosts = [%{node: node(), labels: ["compute"], capacity: 2, available: true}]
    start_supervised!({Service, journal: :memory, pools: [workers: [hosts: hosts]]})
    barrier = OperationBarrier.attach(self(), "lost-reply")
    on_exit(fn -> :telemetry.detach(barrier) end)
    topology = RequirementScheduling.new!(id: "lost-reply")
    token = Cluster.request_id(Service)
    {:ok, operation} = Cluster.deploy(Service, topology, request_id: token)
    assert_receive {:operation_observed, task, metadata}, 5_000
    assert metadata.operation_id == operation.id
    assert metadata.attempt_id == operation.attempt_id
    assert metadata.phase == :completed
    assert metadata.namespace == "lost-operation-result"
    assert length(metadata.claim_ids) == 1
    {:ok, config} = Cluster.config(Service)
    {:ok, ref} = Cluster.ref(Service, topology.id, :worker)
    assert {:ok, agent} = Jido.resolve_agent(config.jido, ref)
    assert Process.alive?(agent)
    assert {:error, :timeout} = Cluster.await(Service, operation.id, 0)

    Process.exit(task, :kill)
    assert {:ok, %{phase: :uncertain, reason: {:task_exit, :killed}}} = Cluster.await(Service, operation.id)
    assert [%{state: :uncertain, ref: ^ref}] = Cluster.claims(Service)

    assert {:error, {:resources_uncertain, _}} =
             Cluster.enable_host(Service, node(), request_id: Cluster.request_id(Service))

    assert {:ok, %{id: id, phase: :uncertain}} = Cluster.deploy(Service, topology, request_id: token)
    assert id == operation.id

    assert {:error, {:resources_uncertain, [_]}} =
             Cluster.deploy(Service, RequirementScheduling.new!(id: "conflict"),
               request_id: Cluster.request_id(Service)
             )

    assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(config.jido))
    assert {:ok, ^agent} = Jido.resolve_agent(config.jido, ref)

    {:ok, stop} = Cluster.stop(Service, topology.id, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :uncertain}} = Cluster.await(Service, stop.id)
    assert {:ok, %{agent_readiness: :uncertain, desired: :stopped}} = Cluster.status(Service, topology.id)
    assert :ok = stop_supervised(Service)
    refute Process.alive?(agent)
  end
end
