defmodule JidoCluster.HostControlTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster
  alias Jido.Cluster.HostProvider.Step
  alias Jido.Cluster.HostRuntime
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling
  import JidoCluster.Test.Eventually

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "host-control"
  end

  test "drain exclusion remains until an explicit idempotent enable request" do
    hosts = [%{node: node(), labels: ["compute"], capacity: 1, available: true}]
    start_supervised!({Service, journal: :memory, pools: [workers: [hosts: hosts]]})
    {:ok, drain} = Cluster.drain(Service, node(), request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, drain.id)
    topology = RequirementScheduling.new!(id: "after-drain")
    assert {:error, {:no_capacity, "worker"}} = Cluster.plan(Service, topology)

    token = Cluster.request_id(Service)
    assert {:ok, enabled} = Cluster.enable_host(Service, node(), request_id: token)
    assert enabled.phase == :completed
    assert enabled.action == :enable_host
    assert {:ok, ^enabled} = Cluster.enable_host(Service, node(), request_id: token)
    assert {:ok, ^enabled} = Cluster.operation(Service, enabled.id)
    assert {:error, :request_conflict} = Cluster.drain(Service, node(), request_id: token)
    assert {:ok, _} = Cluster.plan(Service, topology)
    assert {:error, :unknown_host} = Cluster.enable_host(Service, :unknown, request_id: Cluster.request_id(Service))
  end

  test "attachment waits for a guard whose former core has stopped" do
    jido = __MODULE__.RestartCore
    start_supervised!({Jido, name: jido, namespace: "guard-restart"})
    assert :ignore = HostRuntime.attach(jido: jido)
    previous = Process.whereis(HostRuntime.name(jido))
    :ok = :sys.suspend(previous)

    on_exit(fn ->
      if Process.alive?(previous), do: :sys.resume(previous)
    end)

    stop_supervised!(jido)
    current_core = start_supervised!({Jido, name: jido, namespace: "guard-restart"})

    task =
      Task.async(fn ->
        receive do
          :attach -> HostRuntime.attach(jido: jido)
        end
      end)

    task_pid = task.pid
    :erlang.trace(task_pid, true, [:send, {:tracer, self()}])
    send(task_pid, :attach)
    assert_receive {:trace, ^task_pid, :send, {:"$gen_call", _, {:attached_core, ^current_core}}, ^previous}, 5_000
    :ok = :sys.resume(previous)
    assert :ignore = Task.await(task)
    current = Process.whereis(HostRuntime.name(jido))
    refute current == previous
    assert {:ok, %{namespace: "guard-restart"}} = HostRuntime.probe(current, [])
  end

  test "provider retirement remains closed across guard restart and rejects another step" do
    jido = __MODULE__.ReleaseCore
    start_supervised!({Jido, name: jido, namespace: "retiring-host"})
    host = start_supervised!({HostRuntime, jido: jido})
    {:ok, info} = HostRuntime.probe(host, [])
    scope = {"retiring-host", "default"}
    assert :ok = HostRuntime.register(host, self(), scope, info.incarnation)
    {:ok, ref} = Jido.agent_ref(jido, "retained")

    claim = %{
      id: "claim",
      ref: ref,
      operation_id: "op",
      host_incarnation: info.incarnation,
      scope: scope,
      allocation: "default"
    }

    assert :ok = HostRuntime.confirm(host, self(), scope, info.incarnation, 1, [claim])
    assert {:error, :claims_retained} = HostRuntime.retire(host, self(), scope, info.incarnation, "release-1")
    assert :ok = HostRuntime.release(host, self(), scope, info.incarnation, [claim.id], :confirmed)
    assert :ok = HostRuntime.retire(host, self(), scope, info.incarnation, "release-1")
    assert {:error, :host_retiring} = HostRuntime.register(host, self(), scope, info.incarnation)
    assert {:error, :host_retiring} = HostRuntime.reconcile(host, self(), scope, info.incarnation, [])
    monitor = Process.monitor(host)
    Process.exit(host, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^host, :killed}
    name = HostRuntime.name(jido)
    eventually(fn -> is_pid(Process.whereis(name)) and Process.whereis(name) != host end)
    {:ok, current} = HostRuntime.probe(name, [])
    assert HostRuntime.status(name).allocations["default"].retiring_step == "release-1"
    assert {:error, :stale_incarnation} = HostRuntime.retire(name, self(), scope, info.incarnation, "release-1")
    assert {:error, :host_retiring} = HostRuntime.register(name, self(), scope, current.incarnation)
    assert :ok = HostRuntime.retire(name, self(), scope, current.incarnation, "release-1")
    assert {:error, :release_step_changed} = HostRuntime.retire(name, self(), scope, current.incarnation, "release-2")
  end

  test "a provider boot step cannot change during the same Core lifetime" do
    jido = __MODULE__.ProviderCore
    start_supervised!({Jido, name: jido, namespace: "provider-boot"})

    {:ok, step} =
      Step.new(%{
        namespace: "provider-boot",
        scope: "default",
        host: Atom.to_string(node()),
        provider: "test",
        id: "boot-1"
      })

    record = Step.to_record(step)
    host = start_supervised!({HostRuntime, jido: jido, provider_step: record})
    assert {:ok, %{provider_step: ^record}} = HostRuntime.probe(host, provider_step: record)
    other = Step.to_record(%{step | id: "boot-2"})
    assert {:error, {:incompatible, :provider_step}} = HostRuntime.probe(host, provider_step: other)
    stop_supervised!(HostRuntime)
    assert {:error, {:provider_step_changed, _}} = start_supervised({HostRuntime, jido: jido, provider_step: other})
    assert {:error, {:provider_step_changed, _}} = start_supervised({HostRuntime, jido: jido})
    current = start_supervised!({HostRuntime, jido: jido, provider_step: record})
    assert {:ok, %{provider_step: ^record}} = HostRuntime.probe(current, provider_step: record)
  end
end
