defmodule JidoCluster.EntityTest do
  use ExUnit.Case, async: false

  alias Jido.Cluster
  alias Jido.Cluster.Entity
  alias Jido.Cluster.Entity.Identity
  alias Jido.Topology.Controller
  alias JidoCluster.Test.TopologyCounter, as: Counter
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "entity-contract"
  end

  setup context do
    capacity = Map.get(context, :capacity, 10)
    hosts = [%{node: node(), labels: ["compute"], capacity: capacity, available: true}]
    start_supervised!({Service, journal: :memory, pools: [workers: [hosts: hosts]]})

    {:ok, workload} =
      Entity.new(definition_id: "devices/v1", keyspace: "devices", agent: Counter, requirements: ["compute"])

    %{workload: workload}
  end

  test "versioned keys are stable, type distinct, and validate the declared keyspace", c do
    for key <- [{"devices", 1}, {"devices", "1"}, {"devices", "device/a"}] do
      assert {:ok, id} = Identity.id(c.workload.definition_id, c.workload.keyspace, key)
      assert byte_size(id) <= 255
      assert {:ok, %{identity: ^key, definition_id: "devices/v1", keyspace: "devices"}} = Identity.parse(id)
    end

    {:ok, integer_id} = Identity.id("devices/v1", "devices", {"devices", 1})
    {:ok, string_id} = Identity.id("devices/v1", "devices", {"devices", "1"})
    refute integer_id == string_id
    assert {:error, :invalid_identity} = Identity.id("devices/v1", "devices", nil)
    assert {:error, :invalid_identity} = Identity.id("devices/v1", "devices", "device")
    assert {:error, :keyspace_mismatch} = Identity.id("devices/v1", "devices", {"other", 1})
    assert {:error, :identity_too_large} = Identity.id("devices/v1", nil, String.duplicate("x", 300))
    assert {:error, :invalid_entity_id} = Identity.parse(integer_id <> "x")
  end

  test "workloads reject the removed checkpoint import mode" do
    assert {:error, :invalid_entity_workload} =
             Entity.new(definition_id: "devices/v1", agent: Counter, identity_mode: :require_imported)
  end

  test "simultaneous first requests share one admitted activation and one core Ref", c do
    key = {"devices", "first"}
    assert {:error, :not_found} = Entity.lookup(Service, c.workload, key)
    parent = self()

    tasks =
      for _ <- 1..12 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Entity.ensure(Service, c.workload, key)
          after
            5_000 -> {:error, :barrier_timeout}
          end
        end)
      end

    waiters =
      for _ <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(waiters, &send(&1, :go))
    results = Task.await_many(tasks, 15_000)
    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert [operation_id] = results |> Enum.map(fn {:ok, value} -> value.operation.id end) |> Enum.uniq()
    assert [ref] = results |> Enum.map(fn {:ok, value} -> value.ref end) |> Enum.uniq()
    assert Enum.count(results, &match?({:ok, %{status: :accepted}}, &1)) == 1
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation_id, 5_000)
    assert [%{ref: ^ref, state: :active}] = Cluster.claims(Service)
    assert {:ok, %{pid: pid}} = Entity.lookup(Service, c.workload, key)
    assert {:ok, %{state: %{count: 1}}} = Entity.call(Service, c.workload, key, Counter.increment_signal!())
    assert %{agent: %{id: agent_id, state: %{count: 1}}, state_version: 1} = Jido.AgentServer.snapshot(pid)
    assert ref.id == agent_id
    assert {:ok, %{pid: ^pid}} = Cluster.lookup(Service, ref)
  end

  test "an old workload definition cannot silently reuse an admitted identity", c do
    key = {"devices", "one"}
    assert {:ok, first} = Entity.ensure(Service, c.workload, key)
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, first.operation.id)
    changed = %{c.workload | initial_state: %{count: 7}}
    assert {:error, :entity_definition_conflict} = Entity.ensure(Service, changed, key)
    assert {:error, :entity_definition_conflict} = Entity.lookup(Service, changed, key)
  end

  @tag capacity: 1
  test "declared demand and entity demand share the last slot", c do
    topology = RequirementScheduling.new!(id: "declared")
    assert {:ok, declared} = Cluster.deploy(Service, topology, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, declared.id)
    assert {:error, {:no_capacity, "entity"}} = Entity.ensure(Service, c.workload, {"devices", "blocked"})
    {:ok, config} = Cluster.config(Service)
    assert Controller.whereis(config.jido, "entity:v1:blocked") == nil

    assert {:ok, stop} = Cluster.stop(Service, "declared", request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, stop.id)
    assert {:ok, admitted} = Entity.ensure(Service, c.workload, {"devices", "blocked"})
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, admitted.operation.id)
    assert [%{topology_id: id, state: :active}] = Cluster.claims(Service)
    assert id == admitted.topology_id
  end

  test "bounded active identities reject a ninth before starting a controller", c do
    for index <- 1..8 do
      assert {:ok, accepted} = Entity.ensure(Service, c.workload, {"devices", index})
      assert {:ok, %{phase: :completed}} = Cluster.await(Service, accepted.operation.id)
    end

    assert {:error, :entity_limit} = Entity.ensure(Service, c.workload, {"devices", 9})
    assert length(Cluster.claims(Service)) == 8
  end
end
