defmodule JidoCluster.Test.JournalSnapshot do
  @moduledoc false
  import ExUnit.Assertions
  alias Jido.Cluster.{Activation, Admission, Drain, Journal}
  alias Jido.Cluster.Journal.Snapshot
  alias Jido.Codec.Registry
  alias JidoCluster.Test.PlacementWorker, as: Worker
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  def fixture do
    namespace = "aggregate-contract"
    config = %{namespace: namespace, scope: "scope", hosts: [host(:source), host(:target)]}
    {:ok, ledger} = Admission.new({namespace, config.scope}, config.hosts)

    state = %{
      config: config,
      ledger: ledger,
      generation: Jido.generate_id(),
      epoch: 0,
      operations: %{},
      requests: %{},
      deployments: %{}
    }

    state = Enum.reduce(1..16, state, &add_deployment/2)
    state = Enum.reduce(1..47, state, fn _, state -> bind(state, operation(state, :enable_host, nil)) end)
    operation = operation(state, :drain, nil)
    {:ok, ledger, steps} = Drain.plan(state.ledger, state.deployments, :source, operation.id)

    operation =
      Map.merge(operation, %{
        phase: :accepted,
        steps:
          Map.new(steps, fn step ->
            {step.id, step |> Map.take([:operation_id, :selected, :arrivals, :retired]) |> Map.put(:phase, :accepted)}
          end)
      })

    state = bind(state, operation)
    deployments = Map.new(state.deployments, fn {id, d} -> {id, %{d | operation: operation.id, phase: :accepted}} end)
    state = %{state | ledger: ledger, deployments: deployments}
    topology = state.deployments["deployment-1"].instance

    registry =
      Registry.new!(%{
        "schema/v1" => {:schema, topology.definition.schema},
        "worker/v1" => {:agent, Worker},
        "node" => {:atom, :node}
      })

    %{state: state, registry: registry, config: config}
  end

  def exercise(adapter) do
    %{state: state, registry: registry, config: config} = fixture()
    assert {:ok, document} = Snapshot.encode(state, registry)
    assert map_size(state.deployments) == 16
    assert map_size(state.requests) == 64
    assert length(Admission.claims(state.ledger)) == 32
    assert {:ok, journal} = Journal.open(adapter, {config.namespace, config.scope})

    {elapsed, saved} =
      :timer.tc(fn ->
        Enum.reduce(1..25, journal, fn _, current ->
          assert {:ok, next} = Journal.commit(current, document)
          next
        end)
      end)

    assert {:ok, reread} = Journal.reload(saved)
    assert {:ok, restored} = Snapshot.decode(reread.record, config, registry)
    assert restored.requests == state.requests
    assert restored.operations == state.operations
    assert restored.ledger == state.ledger
    %{journal: saved, bytes: byte_size(saved.expected), writes: 25, write_microseconds: elapsed}
  end

  defp add_deployment(index, state) do
    instance = RequirementScheduling.new!(id: "deployment-#{index}")
    operation = operation(state, :deploy, instance.id)
    selected = %{"worker" => :source}

    {:ok, ledger} =
      Admission.reserve(
        state.ledger,
        instance.id,
        Drain.demand(instance, state.config.namespace, selected),
        operation.id
      )

    {:ok, ledger, _} = Admission.bind_host(ledger, operation.id, :source, "source-incarnation")

    deployment = %{
      activation: Activation.new(state.ledger.scope, instance.id),
      instance: instance,
      selected: selected,
      runner: nil,
      desired: :running,
      phase: :completed,
      reason: nil,
      operation: operation.id
    }

    state = bind(state, operation)

    %{
      state
      | ledger: Admission.mark(ledger, operation.id, :active),
        deployments: Map.put(state.deployments, instance.id, deployment)
    }
  end

  defp operation(state, action, topology) do
    op = %{
      id: Jido.generate_id(),
      attempt_id: Jido.generate_id(),
      action: action,
      topology_id: topology,
      phase: :completed,
      reason: nil,
      namespace: state.config.namespace,
      scope: state.config.scope
    }

    if action in [:drain, :enable_host], do: Map.put(op, :host, :source), else: op
  end

  defp bind(state, op) do
    token = %{scope: state.ledger.scope, generation: state.generation, epoch: state.epoch, nonce: Jido.generate_id()}

    %{
      state
      | requests: Map.put(state.requests, token, {:crypto.hash(:sha256, op.id), op.id}),
        operations: Map.put(state.operations, op.id, op)
    }
  end

  defp host(node), do: %{node: node, labels: ["compute"], capacity: 16, available: true, allocation: "default"}
end
