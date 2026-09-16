defmodule JidoCluster.JournalSnapshotTest do
  use ExUnit.Case, async: true
  alias Jido.Cluster.{Activation, Admission, Drain, Journal}
  alias Jido.Cluster.Federation.Intent
  alias Jido.Cluster.Journal.Snapshot
  alias Jido.Codec.Registry
  alias JidoCluster.Test.JournalSnapshot
  alias JidoCluster.Test.PlacementWorker, as: Worker
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  setup do
    topology = RequirementScheduling.new!(id: "worker-set")

    registry =
      Registry.new!(%{
        "schema/v1" => {:schema, topology.definition.schema},
        "worker/v1" => {:agent, Worker},
        "node" => {:atom, :node}
      })

    config = %{namespace: "snapshot", scope: "scope", hosts: [host(:source), host(:target)]}
    {:ok, ledger} = Admission.new({config.namespace, config.scope}, config.hosts)
    selected = %{"worker" => :source}
    demand = Drain.demand(topology, config.namespace, selected)
    {:ok, ledger} = Admission.reserve(ledger, topology.id, demand, "deploy")
    {:ok, ledger, _} = Admission.bind_host(ledger, "deploy", :source, "source-incarnation")
    ledger = Admission.mark(ledger, "deploy", :active)

    deployment = %{
      activation: Activation.new(ledger.scope, topology.id),
      instance: topology,
      selected: selected,
      runner: self(),
      desired: :running,
      phase: :completed,
      reason: nil,
      operation: "deploy"
    }

    operation = %{
      id: "deploy",
      attempt_id: "attempt",
      action: :deploy,
      topology_id: topology.id,
      phase: :completed,
      reason: nil,
      namespace: config.namespace,
      scope: config.scope
    }

    token = %{scope: ledger.scope, generation: Jido.generate_id(), epoch: 0, nonce: Jido.generate_id()}

    state = %{
      config: config,
      ledger: ledger,
      generation: token.generation,
      epoch: 0,
      operations: %{"deploy" => operation},
      requests: %{token => {:crypto.hash(:sha256, "deploy"), "deploy"}},
      deployments: %{topology.id => deployment},
      tasks: %{make_ref() => "deploy"},
      waiters: %{}
    }

    %{state: state, registry: registry, config: config, token: token}
  end

  test "JSON restores intent, identity, bindings and claims without runtime processes", c do
    assert {:ok, document} = Snapshot.encode(c.state, c.registry)
    stored = document |> Jason.encode!() |> Jason.decode!()
    assert {:ok, restored} = Snapshot.decode(stored, c.config, c.registry)
    assert restored.generation == c.state.generation
    assert restored.requests == c.state.requests
    assert restored.operations == c.state.operations
    assert restored.ledger == c.state.ledger
    assert restored.deployments["worker-set"].runner == nil
    assert restored.deployments["worker-set"].instance == c.state.deployments["worker-set"].instance
    refute Map.has_key?(restored, :tasks)
    refute Map.has_key?(restored, :waiters)
  end

  test "an interrupted drain retains its complete transition and source exclusion", c do
    {:ok, ledger, [step]} = Drain.plan(c.state.ledger, c.state.deployments, :source, "drain")
    intent = step |> Map.take([:operation_id, :selected, :arrivals, :retired]) |> Map.put(:phase, :accepted)
    op = %{c.state.operations["deploy"] | id: "drain", action: :drain, topology_id: nil, phase: :uncertain}
    op = Map.merge(op, %{host: :source, steps: %{step.id => intent}})
    deployment = %{c.state.deployments[step.id] | phase: :uncertain, operation: "drain"}

    state = %{
      c.state
      | ledger: ledger,
        operations: Map.put(c.state.operations, "drain", op),
        deployments: %{step.id => deployment}
    }

    {:ok, document} = Snapshot.encode(state, c.registry)
    assert {:ok, restored} = Snapshot.decode(document, c.config, c.registry)
    assert restored.operations["drain"].steps == op.steps
    assert MapSet.member?(restored.ledger.excluded, :source)
    assert length(Admission.claims(restored.ledger)) == 2
    assert restored.deployments[step.id].phase == :uncertain
  end

  test "stopped intent remains after completed request expiry", c do
    {:ok, ledger} = Admission.release(c.state.ledger, "worker-set", :confirmed)
    deployment = %{c.state.deployments["worker-set"] | desired: :stopped, runner: nil}

    state = %{
      c.state
      | ledger: ledger,
        operations: %{},
        requests: %{},
        epoch: 1,
        deployments: %{"worker-set" => deployment}
    }

    {:ok, document} = Snapshot.encode(state, c.registry)
    assert {:ok, restored} = Snapshot.decode(document, c.config, c.registry)
    assert restored.deployments["worker-set"].desired == :stopped
    assert restored.requests == %{}
    assert Admission.claims(restored.ledger) == []
    assert restored.epoch == 1
  end

  test "changed inventory, duplicate claims and invented refs or phases fail closed", c do
    {:ok, document} = Snapshot.encode(c.state, c.registry)
    [claim] = document["claims"]

    changes = [
      Map.put(document, "claims", [claim, claim]),
      put_in(document, ["claims", Access.at(0), "host"], "untrusted@host"),
      put_in(document, ["claims", Access.at(0), "ref"], "unrelated-agent"),
      put_in(document, ["claims", Access.at(0), "allocation"], "other-budget"),
      put_in(document, ["operations", Access.at(0), "phase"], "invented-phase"),
      put_in(document, ["requests", Access.at(0), "operation"], "missing"),
      Map.put(document, "epoch", 0.0),
      Map.put(document, "version", 1.0),
      Map.put(document, "extra", "unsupported")
    ]

    for changed <- changes, do: assert({:error, _} = Snapshot.decode(changed, c.config, c.registry))
    changed_config = %{c.config | hosts: [host(:source, 2), host(:target)]}
    assert {:error, _} = Snapshot.decode(document, changed_config, c.registry)
  end

  test "admission bytes leave space for bounded observations", c do
    large = String.duplicate("a", Journal.limits().admission_bytes)
    topology = c.state.deployments["worker-set"].instance
    topology = %{topology | definition: %{topology.definition | metadata: %{"large" => large}}}
    state = put_in(c.state, [:deployments, "worker-set", :instance], topology)
    assert {:error, {:aggregate_too_large, _, 65_536}} = Snapshot.encode(state, c.registry)
    assert {:ok, _} = Snapshot.encode(state, c.registry, :observation)
    reason = {:lost, self(), make_ref(), String.duplicate("x", 100_000)}
    state = put_in(c.state, [:operations, "deploy", :reason], reason)
    assert {:ok, document} = Snapshot.encode(state, c.registry)
    assert byte_size(hd(document["operations"])["reason"]) <= 512
    assert {:ok, restored} = Snapshot.decode(document, c.config, c.registry)
    assert {:recorded_reason, _} = restored.operations["deploy"].reason
    assert {:ok, ^document} = Snapshot.encode(restored |> Map.put(:config, c.config), c.registry)
  end

  test "portable fingerprints ignore rebuilt runtime plans and include desired input", c do
    topology = c.state.deployments["worker-set"].instance
    assert {:ok, fingerprint} = Snapshot.fingerprint(:deploy, topology, c.registry)
    assert {:ok, ^fingerprint} = Snapshot.fingerprint(:deploy, %{topology | plan: nil}, c.registry)
    assert {:ok, other} = Snapshot.fingerprint(:deploy, %{topology | id: "different"}, c.registry)
    refute other == fingerprint
    assert {:error, _} = Snapshot.fingerprint(:deploy, topology, %{})
  end

  test "binding lifecycle intent survives JSON and legacy declarations require fresh attachment", c do
    d = c.state.deployments["worker-set"]

    metadata = %{
      "jido.cluster.federation" => %{
        "version" => 1,
        "channels" => [%{"key" => "events", "types" => ["counter.changed"]}],
        "bindings" => [%{"agent" => "worker", "channel" => "events", "required" => true}]
      }
    }

    instance = %{d.instance | definition: %{d.instance.definition | metadata: metadata}}
    {:ok, intent} = Intent.new(instance, d.selected, d.activation)
    {:ok, intent} = Intent.attaching(intent, instance.id, Admission.claims(c.state.ledger))
    intent = Intent.ready(intent)
    d = d |> Map.put(:instance, instance) |> Map.put(:federation, intent)
    state = put_in(c.state, [:deployments, instance.id], d)
    assert {:ok, document} = Snapshot.encode(state, c.registry)
    assert {:ok, restored} = Snapshot.decode(Jason.decode!(Jason.encode!(document)), c.config, c.registry)
    assert restored.deployments[instance.id].federation == intent
    legacy = update_in(document, ["deployments", Access.at(0)], &Map.delete(&1, "federation"))
    assert {:ok, restored} = Snapshot.decode(legacy, c.config, c.registry)
    assert restored.deployments[instance.id].federation["phase"] == "planned"
    assert hd(restored.deployments[instance.id].federation["bindings"])["incarnation"] == nil
    invalid = put_in(document, ["deployments", Access.at(0), "federation"], nil)
    assert {:error, {:invalid_snapshot, :invalid_binding_intent}} = Snapshot.decode(invalid, c.config, c.registry)
  end

  test "record counts and unresolved operations have independent hard bounds", c do
    {:ok, document} = Snapshot.encode(c.state, c.registry)

    for {field, limit} <- [{"deployments", 16}, {"claims", 64}, {"requests", 64}, {"hosts", 32}] do
      changed = Map.put(document, field, List.duplicate(hd(document[field]), limit + 1))
      assert {:error, {:invalid_snapshot, :collection_limit}} = Snapshot.decode(changed, c.config, c.registry)
    end

    op = hd(document["operations"])
    ops = for index <- 1..17, do: %{op | "id" => "pending-#{index}", "phase" => "uncertain"}

    assert {:error, {:invalid_snapshot, :operation_limit}} =
             Snapshot.decode(%{document | "operations" => ops}, c.config, c.registry)
  end

  test "a record cannot restore capacity with missing claims or repeated Ref reservations", c do
    {:ok, document} = Snapshot.encode(c.state, c.registry)
    [claim] = document["claims"]
    assert {:error, _} = Snapshot.decode(%{document | "claims" => []}, c.config, c.registry)
    duplicate_ref = %{claim | "host" => "target"}
    assert {:error, _} = Snapshot.decode(%{document | "claims" => [claim, duplicate_ref]}, c.config, c.registry)
  end

  test "a full retention epoch with sixteen pending moves fits the admission record" do
    fixture = JournalSnapshot.fixture()
    assert {:ok, document} = Snapshot.encode(fixture.state, fixture.registry)
    assert byte_size(Jason.encode!(document)) < Journal.limits().admission_bytes
    assert {:ok, restored} = Snapshot.decode(document, fixture.config, fixture.registry)
    assert restored.requests == fixture.state.requests
    assert restored.ledger == fixture.state.ledger
  end

  defp host(node, capacity \\ 1),
    do: %{node: node, labels: ["compute"], capacity: capacity, available: true, allocation: "default"}
end
