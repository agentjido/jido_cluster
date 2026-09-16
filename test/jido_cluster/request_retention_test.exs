defmodule JidoCluster.RequestRetentionTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster
  alias JidoCluster.Test.OperationBarrier
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "request-retention"
  end

  setup do
    hosts = [%{node: node(), labels: ["compute"], capacity: 1, available: true}]
    start_supervised!({Service, journal: :memory, pools: [workers: [hosts: hosts]]})
    :ok
  end

  test "a completed epoch expires old tokens but keeps live placement and claims" do
    token = Cluster.request_id(Service)
    {:ok, operation} = Cluster.deploy(Service, RequirementScheduling.new!(id: "kept"), request_id: token)
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    {:ok, ref} = Cluster.ref(Service, "kept", :worker)
    {:ok, %{pid: pid}} = Cluster.lookup(Service, ref)
    {:ok, %{activation: activation}} = Cluster.status(Service, "kept")
    fill_completed(63)
    assert %{retention: %{requests: 64, epoch: 0}} = Cluster.status(Service)
    next = Cluster.request_id(Service)
    assert next.epoch == 1
    assert next.generation == token.generation
    assert %{retention: %{requests: 0, epoch: 1}} = Cluster.status(Service)

    assert {:error, :expired_request} =
             Cluster.deploy(Service, RequirementScheduling.new!(id: "kept"), request_id: token)

    assert {:error, :not_found} = Cluster.operation(Service, operation.id)
    assert [%{ref: ^ref, state: :active}] = Cluster.claims(Service)
    assert {:ok, %{pid: ^pid}} = Cluster.lookup(Service, ref)
    assert {:ok, %{activation: ^activation}} = Cluster.status(Service, "kept")
    assert {:ok, {:active, _}} = Cluster.Activation.inspect(activation)
    {:ok, stop} = Cluster.stop(Service, "kept", request_id: next)
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, stop.id)
    refute Process.alive?(pid)
    assert {:ok, :settled} = Cluster.Activation.inspect(activation)
  end

  test "an uncertain binding prevents expiry and survives retention saturation" do
    fill_completed(63)
    barrier = OperationBarrier.attach(self(), "uncertain")
    on_exit(fn -> :telemetry.detach(barrier) end)
    topology = RequirementScheduling.new!(id: "uncertain")
    token = Cluster.request_id(Service)
    {:ok, operation} = Cluster.deploy(Service, topology, request_id: token)
    assert_receive {:operation_observed, task, _metadata}, 5_000
    Process.exit(task, :kill)
    assert {:ok, %{phase: :uncertain}} = Cluster.await(Service, operation.id)
    assert {:error, :retention_saturated} = Cluster.request_id(Service)
    assert {:ok, %{id: id, phase: :uncertain}} = Cluster.deploy(Service, topology, request_id: token)
    assert id == operation.id
    assert %{retention: %{epoch: 0, requests: 64, unresolved_operations: 1}} = Cluster.status(Service)
    assert [%{state: :uncertain}] = Cluster.claims(Service)
    {:ok, config} = Cluster.config(Service)
    assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(config.jido))
  end

  test "token fields cannot be extended or changed to another numeric type" do
    token = Cluster.request_id(Service)

    for malformed <- [Map.put(token, :extra, 1), %{token | epoch: 0.0}] do
      assert {:error, :invalid_request_id} = Cluster.enable_host(Service, node(), request_id: malformed)
    end
  end

  test "stopped deployments retain their intent and consume the deployment limit" do
    for index <- 1..16 do
      topology = RequirementScheduling.new!(id: "retained-#{index}")
      {:ok, deploy} = Cluster.deploy(Service, topology, request_id: Cluster.request_id(Service))
      assert {:ok, %{phase: :completed}} = Cluster.await(Service, deploy.id)
      {:ok, stop} = Cluster.stop(Service, topology.id, request_id: Cluster.request_id(Service))
      assert {:ok, %{phase: :completed}} = Cluster.await(Service, stop.id)
    end

    assert {:error, :deployment_limit} =
             Cluster.deploy(Service, RequirementScheduling.new!(id: "overflow"),
               request_id: Cluster.request_id(Service)
             )

    assert {:ok, %{desired: :stopped, phase: :completed}} = Cluster.status(Service, "retained-1")
    assert Cluster.claims(Service) == []
    {:ok, config} = Cluster.config(Service)
    assert %{active: 0} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(config.jido))
  end

  defp fill_completed(count) do
    for _ <- 1..count do
      assert {:ok, %{phase: :completed}} =
               Cluster.enable_host(Service, node(), request_id: Cluster.request_id(Service))
    end
  end
end
