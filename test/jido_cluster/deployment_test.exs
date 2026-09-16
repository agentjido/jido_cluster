defmodule JidoCluster.DeploymentTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster
  alias Jido.Cluster.HostRuntime
  alias Jido.Topology.Controller
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "deployment-contract"
  end

  setup do
    hosts = [%{node: node(), labels: ["compute"], capacity: 2, available: true}]
    start_supervised!({Service, journal: :memory, pools: [workers: [hosts: hosts]]})
    {:ok, config} = Cluster.config(Service)
    %{config: config, topology: RequirementScheduling.new!(id: "workload")}
  end

  test "plan starts nothing; deploy returns a stable operation and routes a core Ref", c do
    assert {:ok, %{placements: %{"worker" => host}}} = Cluster.plan(Service, c.topology)
    assert host == node()
    assert Controller.whereis(c.config.jido, "workload") == nil
    token = Cluster.request_id(Service)
    assert {:ok, accepted} = Cluster.deploy(Service, c.topology, request_id: token)
    assert accepted.phase == :accepted
    assert {:ok, done} = Cluster.await(Service, accepted.id, 5_000)
    assert done.phase == :completed
    assert {:ok, same} = Cluster.deploy(Service, c.topology, request_id: token)
    assert same.id == accepted.id

    assert {:error, :request_conflict} =
             Cluster.deploy(Service, RequirementScheduling.new!(id: "other"), request_id: token)

    assert {:ok, ref} = Cluster.ref(Service, "workload", :worker)
    assert ref.namespace == c.config.namespace
    assert {:ok, %{pid: pid, status: :ready}} = Cluster.lookup(Service, ref)
    assert Process.alive?(pid)
    assert {:ok, %{agent_readiness: :ready, binding_readiness: :ready}} = Cluster.status(Service, "workload")

    assert {:ok, stop} = Cluster.stop(Service, "workload", request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, stop.id, 5_000)
    refute Process.alive?(pid)
    assert {:error, :stopped} = Cluster.lookup(Service, ref)
    assert Controller.whereis(c.config.jido, "workload") == nil
    # A completed stop cannot be undone by a supervisor restart policy.
    assert {:ok, %{desired: :stopped}} = Cluster.status(Service, "workload")
  end

  test "service shutdown settles owned deployment cleanup before stopping core", c do
    {:ok, op} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert {:ok, _} = Cluster.await(Service, op.id, 5_000)
    {:ok, ref} = Cluster.ref(Service, "workload", :worker)
    {:ok, %{pid: agent}} = Cluster.lookup(Service, ref)
    controller = Controller.whereis(c.config.jido, "workload")
    core = Process.whereis(c.config.jido)
    assert :ok = stop_supervised(Service)
    for pid <- [agent, controller, core], do: refute(Process.alive?(pid))
  end

  test "invalid tokens and unsupported workloads fail before activation", c do
    assert {:error, :invalid_request_id} = Cluster.deploy(Service, c.topology, request_id: "old")
    assert {:error, :invalid_topology} = Cluster.plan(Service, %{})
    assert Controller.whereis(c.config.jido, "workload") == nil
  end

  test "caller-supplied plans cannot replace core identity", c do
    forged = %{c.topology | plan: %{c.topology.plan | agents: %{}}}
    {:ok, op} = Cluster.deploy(Service, forged, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, op.id, 5_000)
    # Recovery must resolve the same registration used at startup. Otherwise
    # it can miss the old runner and race its shutdown when replacing work.
    {:ok, config} = Cluster.config(Service)
    assert is_pid(Cluster.Deployment.whereis(config.jido, "workload"))
    assert {:ok, %{id: "workload/agent/worker"}} = Cluster.ref(Service, "workload", :worker)
  end

  test "stopped intent does not report stopped readiness when cleanup is uncertain", c do
    host = HostRuntime.name(c.config.jido)
    {:ok, identity} = HostRuntime.probe(host, [])
    :ok = HostRuntime.register(host, self(), "other-scope", identity.incarnation)
    {:ok, deploy} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))

    assert {:ok, %{phase: :uncertain, reason: {:host_rejected, failure}}} = Cluster.await(Service, deploy.id)
    assert %{stage: :registration, reason: :scope_already_owned} = failure

    {:ok, stop} = Cluster.stop(Service, "workload", request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :uncertain, reason: :cleanup_uncertain}} = Cluster.await(Service, stop.id)
    assert {:ok, %{desired: :stopped, agent_readiness: :uncertain}} = Cluster.status(Service, "workload")
    assert [%{state: :uncertain}] = Cluster.claims(Service)
  end
end
