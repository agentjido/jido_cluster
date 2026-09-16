defmodule JidoCluster.EntityRecoveryTest do
  use ExUnit.Case, async: false

  alias Jido.Cluster
  alias Jido.Cluster.Entity
  alias JidoCluster.Test.JournalAdapter
  alias JidoCluster.Test.TopologyCounter, as: Counter
  import JidoCluster.Test.Eventually

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster
  end

  test "journal recovery restores one entity Ref, claim, and committed state" do
    journal = start_supervised!({JournalAdapter, []})
    table = :entity_recovery_fixture
    assert {:atomic, :ok} = :mnesia.create_table(table, attributes: [:key, :value], ram_copies: [node()])
    persistence = {Jido.Persistence.Mnesia, table: table}
    {:ok, workload} = Entity.new(definition_id: "devices/v1", keyspace: "devices", agent: Counter)
    {:ok, topology} = Entity.topology(workload, {"devices", "recover"})
    namespace = "entity-recovery/#{Jido.generate_id()}"
    hosts = [%{node: node(), labels: [], capacity: 1, available: true}]

    opts = [
      namespace: namespace,
      journal: {JournalAdapter, server: journal},
      agent_persistence: persistence,
      registry: %{
        "schema/v1" => {:schema, topology.definition.schema},
        "counter/v1" => {:agent, Counter}
      },
      pools: [workers: [hosts: hosts]]
    ]

    start_supervised!({Service, opts})
    assert {:ok, admitted} = Entity.ensure(Service, workload, {"devices", "recover"})
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, admitted.operation.id)

    assert {:ok, %{state: %{count: 1}}} =
             Entity.call(Service, workload, {"devices", "recover"}, Counter.increment_signal!())

    assert {:ok, %{pid: previous}} = Entity.lookup(Service, workload, {"devices", "recover"})
    stop_supervised!(Service)
    refute Process.alive?(previous)
    start_supervised!({Service, opts})
    assert %{status: :reconciliation_required} = Cluster.status(Service)
    assert {:error, :reconciliation_required} = Entity.ensure(Service, workload, {"devices", "recover"})
    assert {:error, :uncertain} = Entity.lookup(Service, workload, {"devices", "recover"})
    assert :ok = Cluster.reconcile(Service)
    eventually(fn -> match?({:ok, %{pid: _}}, Entity.lookup(Service, workload, {"devices", "recover"})) end)
    assert {:ok, %{pid: current}} = Entity.lookup(Service, workload, {"devices", "recover"})
    refute current == previous
    assert %{agent: %{state: %{count: 1}}, state_version: 1} = Jido.AgentServer.snapshot(current)
    assert {:ok, same_ref} = Entity.ref(Service, workload, {"devices", "recover"})
    assert same_ref == admitted.ref
    assert [%{ref: ^same_ref, state: :active}] = Cluster.claims(Service)
    assert {:ok, %{operation: %{phase: :completed}}} = Entity.ensure(Service, workload, {"devices", "recover"})
    stop_supervised!(Service)
    assert {:atomic, :ok} = :mnesia.delete_table(table)
  end

  test "a lost entity admission reply is reconciled without a second activation" do
    journal = start_supervised!({JournalAdapter, []})
    table = :entity_unknown_start_fixture
    assert {:atomic, :ok} = :mnesia.create_table(table, attributes: [:key, :value], ram_copies: [node()])
    {:ok, workload} = Entity.new(definition_id: "devices/v1", keyspace: "devices", agent: Counter)
    {:ok, topology} = Entity.topology(workload, {"devices", "unknown"})
    hosts = [%{node: node(), labels: [], capacity: 1, available: true}]

    start_supervised!(
      {Service,
       namespace: "entity-unknown/#{Jido.generate_id()}",
       journal: {JournalAdapter, server: journal},
       agent_persistence: {Jido.Persistence.Mnesia, table: table},
       registry: %{
         "schema/v1" => {:schema, topology.definition.schema},
         "counter/v1" => {:agent, Counter}
       },
       pools: [workers: [hosts: hosts]]}
    )

    assert :ok = JournalAdapter.mode(journal, :commit_then_lose)
    assert {:error, {:journal_write_failed, _}} = Entity.ensure(Service, workload, {"devices", "unknown"})
    assert %{status: :journal_unavailable} = Cluster.status(Service)
    assert {:error, :uncertain} = Entity.lookup(Service, workload, {"devices", "unknown"})
    assert :ok = Cluster.reconcile(Service)
    eventually(fn -> match?({:ok, %{pid: _}}, Entity.lookup(Service, workload, {"devices", "unknown"})) end)

    assert {:ok, %{operation: %{phase: :completed}, status: :existing, ref: ref}} =
             Entity.ensure(Service, workload, {"devices", "unknown"})

    assert [%{ref: ^ref, state: :active}] = Cluster.claims(Service)
    assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
    stop_supervised!(Service)
    assert {:atomic, :ok} = :mnesia.delete_table(table)
  end
end
