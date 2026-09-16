defmodule JidoCluster.EntityPendingTest do
  use ExUnit.Case, async: false

  alias Jido.Cluster
  alias Jido.Cluster.Entity
  alias JidoCluster.Examples.Support.StartBarrier
  alias JidoCluster.Test.TopologyCounter, as: Counter
  import JidoCluster.Test.Eventually

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "entity-pending"
  end

  test "pending activation does not cause a second start or a Signal replay" do
    table = :entity_pending_fixture
    assert {:atomic, :ok} = :mnesia.create_table(table, attributes: [:key, :value], ram_copies: [node()])
    start_supervised!({StartBarrier, []})
    hosts = [%{node: node(), labels: [], capacity: 1, available: true}]

    start_supervised!(
      {Service,
       journal: :memory, agent_persistence: {StartBarrier.Persistence, table: table}, pools: [workers: [hosts: hosts]]}
    )

    {:ok, workload} = Entity.new(definition_id: "devices/v1", keyspace: "devices", agent: Counter)
    identity = {"devices", "held"}
    assert {:ok, first} = Entity.ensure(Service, workload, identity)
    eventually(fn -> GenServer.call(StartBarrier, :status).waiting == 1 end)
    assert {:error, :pending} = Entity.lookup(Service, workload, identity)
    assert {:ok, same} = Entity.ensure(Service, workload, identity)
    assert same.operation.id == first.operation.id
    assert {:error, :pending} = Entity.call(Service, workload, identity, Counter.increment_signal!(), 100)
    assert [%{state: :reserved}] = Cluster.claims(Service)
    assert %{arrivals: 1, waiting: 1} = GenServer.call(StartBarrier, :status)

    assert :ok = GenServer.call(StartBarrier, :release)
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, first.operation.id)
    assert {:ok, %{pid: pid}} = Entity.lookup(Service, workload, identity)
    assert %{agent: %{state: %{count: 0}}, state_version: 0} = Jido.AgentServer.snapshot(pid)
    assert {:ok, %{state: %{count: 1}}} = Entity.call(Service, workload, identity, Counter.increment_signal!())
    assert %{state_version: 1} = Jido.AgentServer.snapshot(pid)
    stop_supervised!(Service)
    assert {:atomic, :ok} = :mnesia.delete_table(table)
  end
end
