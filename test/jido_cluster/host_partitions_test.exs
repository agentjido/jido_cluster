defmodule JidoCluster.HostPartitionsTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster
  alias Jido.Cluster.HostRuntime
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling
  import JidoCluster.Test.Eventually

  defmodule First do
    use Jido.Cluster, otp_app: :jido_cluster, scope: "first"
  end

  defmodule Second do
    use Jido.Cluster, otp_app: :jido_cluster, scope: "second"
  end

  defmodule Conflict do
    use Jido.Cluster, otp_app: :jido_cluster, scope: "conflict"
  end

  test "explicit partitions share core and guard without sharing their slot budgets" do
    jido = __MODULE__.Core
    start_supervised!({Jido, name: jido, namespace: "partitioned-host"})
    host = start_supervised!({HostRuntime, jido: jido, allocations: %{"blue" => 1, "green" => 1}})

    for {service, allocation} <- [{First, "blue"}, {Second, "green"}, {Conflict, "blue"}] do
      hosts = [%{node: node(), labels: ["compute"], capacity: 1, available: true, allocation: allocation}]
      start_supervised!({service, jido: jido, journal: :memory, pools: [workers: [hosts: hosts]]})
    end

    agents =
      for {service, id, allocation} <- [{First, "first", "blue"}, {Second, "second", "green"}] do
        {:ok, op} = Cluster.deploy(service, RequirementScheduling.new!(id: id), request_id: Cluster.request_id(service))
        assert {:ok, %{phase: :completed}} = Cluster.await(service, op.id)
        assert [%{allocation: ^allocation, state: :active}] = Cluster.claims(service)
        {:ok, ref} = Cluster.ref(service, id, :worker)
        {:ok, %{pid: pid}} = Cluster.lookup(service, ref)
        pid
      end

    assert %{active: 2} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(jido))
    assert %{allocations: %{"blue" => %{capacity: 1}, "green" => %{capacity: 1}}} = HostRuntime.status(host)

    {:ok, rejected} =
      Cluster.deploy(Conflict, RequirementScheduling.new!(id: "conflict"), request_id: Cluster.request_id(Conflict))

    assert {:ok,
            %{
              phase: :uncertain,
              reason: {:host_rejected, %{allocation: "blue", stage: :registration, reason: :scope_already_owned}}
            }} = Cluster.await(Conflict, rejected.id)

    assert %{active: 2} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(jido))

    [first, second] = agents
    stop_supervised!(First)
    refute Process.alive?(first)
    assert Process.alive?(second)
    assert Process.alive?(host)
    assert Process.alive?(Process.whereis(jido))
    stop_supervised!(Second)
    refute Process.alive?(second)
  end

  test "a partition cannot reserve a Ref already confirmed in another partition" do
    jido = __MODULE__.Core
    start_supervised!({Jido, name: jido, namespace: "partitioned-host"})
    host = start_supervised!({HostRuntime, jido: jido, allocations: %{"blue" => 1, "green" => 1}})
    {:ok, info} = HostRuntime.probe(host, [])
    assert :ok = HostRuntime.register(host, self(), "first", info.incarnation, "blue")

    assert {:error, :scope_allocation_conflict} =
             HostRuntime.register(host, self(), "first", info.incarnation, "green")

    assert :ok = HostRuntime.register(host, self(), "second", info.incarnation, "green")
    {:ok, ref} = Jido.agent_ref(jido, "same")

    claim = %{
      id: "first",
      ref: ref,
      operation_id: "op",
      host_incarnation: info.incarnation,
      scope: "first",
      allocation: "blue"
    }

    assert :ok = HostRuntime.confirm(host, self(), "first", info.incarnation, 1, [claim])
    other = %{claim | id: "second", scope: "second", allocation: "green"}
    assert {:error, :ref_already_claimed} = HostRuntime.confirm(host, self(), "second", info.incarnation, 1, [other])
    assert {:error, :unknown_allocation} = HostRuntime.register(host, self(), "other", info.incarnation, "missing")
    assert {:error, :capacity_conflict} = HostRuntime.confirm(host, self(), "second", info.incarnation, 2, [])

    monitor = Process.monitor(host)
    Process.exit(host, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^host, :killed}
    eventually(fn -> is_pid(Process.whereis(HostRuntime.name(jido))) end)
    next = HostRuntime.name(jido)
    {:ok, current} = HostRuntime.probe(next, [])

    assert %{
             allocations: %{
               "blue" => %{control: :reconcile, claims: [^claim], capacity: 1},
               "green" => %{control: :reconcile, claims: [], capacity: 1}
             }
           } = HostRuntime.status(next)

    assert :ok = HostRuntime.reconcile(next, self(), "second", current.incarnation, [], "green")
    assert {:error, :reconciliation_required} = HostRuntime.register(next, self(), "first", current.incarnation, "blue")
    assert :ok = HostRuntime.reconcile(next, self(), "first", current.incarnation, [claim], "blue")

    assert {:error, :ref_already_claimed} =
             HostRuntime.confirm(next, self(), "second", current.incarnation, 1, [
               %{other | host_incarnation: current.incarnation}
             ])
  end
end
