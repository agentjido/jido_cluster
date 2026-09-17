defmodule JidoCluster.Federation.RepairTest do
  use ExUnit.Case, async: false
  import JidoCluster.Test.Eventually
  alias Jido.Cluster
  alias Jido.Cluster.Deployment.Owner
  alias Jido.Cluster.Federation.Mirror
  alias JidoCluster.Test.Federation.{DeclaredTopology, Subscriber}
  alias JidoCluster.Test.JournalAdapter

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "binding-repair"
  end

  setup do
    adapter = start_supervised!(JournalAdapter)
    topology = DeclaredTopology.new!(id: "repair-listener-#{System.unique_integer([:positive])}")
    journal = {JournalAdapter, server: adapter}

    opts = [
      journal: journal,
      registry: %{
        "schema/v1" => {:schema, topology.definition.schema},
        "subscriber/v1" => {:agent, Subscriber},
        "node" => {:atom, :node}
      },
      pools: [workers: [hosts: [%{node: node(), capacity: 2, labels: ["compute"], available: true}]]]
    ]

    start_supervised!({Service, opts})
    {:ok, operation} = Cluster.deploy(Service, topology, request_id: Cluster.request_id(Service))
    assert {:ok, completed} = Cluster.await(Service, operation.id)
    {:ok, ref} = Cluster.ref(Service, topology.id, :listener)
    {:ok, %{pid: agent}} = Cluster.lookup(Service, ref)
    {:ok, %{activation: activation, binding_intent: intent}} = Cluster.status(Service, topology.id)
    {:ok, mirror} = Mirror.lookup(Service.Core, activation, "events")

    %{
      adapter: adapter,
      topology: topology,
      ref: ref,
      agent: agent,
      activation: activation,
      intent: intent,
      mirror: mirror,
      old: Mirror.status(mirror),
      completed: completed,
      claims: Cluster.claims(Service)
    }
  end

  test "explicit bridge repair retains the Agent, claims, and completed operation", c do
    publish(c, "before", ["before"])
    lose_bridge(c)
    assert {:ok, %{agent_readiness: :ready, binding_readiness: readiness}} = Cluster.status(Service, c.topology.id)
    refute readiness == :ready
    repair(c)
    {:ok, replacement} = Mirror.lookup(Service.Core, c.activation, "events")
    assert replacement != c.mirror
    assert Mirror.status(replacement).revision == 1
    assert Cluster.claims(Service) == c.claims
    assert {:ok, %{pid: agent}} = Cluster.lookup(Service, c.ref)
    assert agent == c.agent
    assert {:ok, c.completed} == Cluster.operation(Service, c.completed.id)
    {:ok, %{binding_intent: current, binding_transition: nil}} = Cluster.status(Service, c.topology.id)
    assert current["revision"] == 1
    assert hd(current["bindings"])["id"] == hd(c.intent["bindings"])["id"]
    assert hd(current["bindings"])["incarnation"] == hd(c.intent["bindings"])["incarnation"]
    publish(c, "after", ["before", "after"])
    writes = JournalAdapter.writes(c.adapter)
    assert :ok = Cluster.reconcile(Service)
    eventually(fn -> not Cluster.status(Service).recovering end)
    assert {:ok, ^replacement} = Mirror.lookup(Service.Core, c.activation, "events")
    assert JournalAdapter.writes(c.adapter) == writes
    stop(c)
  end

  test "mirror reconstruction waits for the retirement journal receipt", c do
    lose_bridge(c)
    path = ["record", "deployments", 0, "federation_transition", "phase"]
    :ok = JournalAdapter.when_path(c.adapter, path, "retired", {:hold, self()})
    assert :ok = Cluster.reconcile(Service)
    assert_receive {:journal_written, caller, token}, 5000
    on_exit(fn -> send(caller, {:release, token}) end)
    assert Process.alive?(c.agent)
    assert {:error, :not_found} = Mirror.lookup(Service.Core, c.activation, "events")
    assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
    send(caller, {:release, token})
    ready(c)
    assert {:ok, %{pid: agent}} = Cluster.lookup(Service, c.ref)
    assert agent == c.agent
    assert Cluster.claims(Service) == c.claims
    stop(c)
  end

  test "pending binding cleanup permits independent deployment work", c do
    lose_bridge(c)
    handler = {__MODULE__, make_ref()}
    event = [:jido, :cluster, :federation, :retirement, :start]
    :ok = :telemetry.attach(handler, event, &__MODULE__.hold_retirement/4, {c.topology.id, self()})
    on_exit(fn -> :telemetry.detach(handler) end)
    assert :ok = Cluster.reconcile(Service)
    assert_receive {:retirement_waiting, task}, 2000
    on_exit(fn -> send(task, :continue_retirement) end)
    assert Process.alive?(c.agent)
    assert Cluster.claims(Service) == c.claims
    assert {:error, :busy} = Cluster.stop(Service, c.topology.id, request_id: Cluster.request_id(Service))

    assert {:ok, %{binding_repair: :running, binding_transition: %{"phase" => "retiring"}}} =
             Cluster.status(Service, c.topology.id)

    signal = Jido.Signal.new!(%{id: "independent", type: "counter.changed", source: "/repair-test", data: %{}})
    assert {:error, :not_ready} = Cluster.publish(Service, c.topology.id, :events, signal)

    other = DeclaredTopology.new!(id: "independent-listener")
    {:ok, deployment} = Cluster.deploy(Service, other, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, deployment.id)
    {:ok, ref} = Cluster.ref(Service, other.id, :listener)
    {:ok, %{pid: agent}} = Cluster.lookup(Service, ref)
    assert {:ok, _} = Cluster.publish(Service, other.id, :events, %{signal | id: "independent"})
    eventually(fn -> Enum.map(Jido.AgentServer.snapshot(agent).agent.state.events, & &1.id) == ["independent"] end)
    {:ok, stopped} = Cluster.stop(Service, other.id, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, stopped.id)
    refute Process.alive?(agent)

    :ok = :telemetry.detach(handler)
    send(task, :continue_retirement)
    ready(c)
    assert {:ok, %{pid: agent}} = Cluster.lookup(Service, c.ref)
    assert agent == c.agent
    assert Cluster.claims(Service) == c.claims
    stop(c)
  end

  test "repeated repair retains uncertainty after abrupt mirror loss", c do
    monitor = Process.monitor(c.mirror)
    Process.exit(c.mirror, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 5000
    eventually(fn -> Enum.all?(Map.values(c.old.components), &(not Process.alive?(&1))) end)

    for _ <- 1..2 do
      assert :ok = Cluster.reconcile(Service)
      eventually(fn -> not Cluster.status(Service).recovering end)

      assert {:ok,
              %{
                agent_readiness: :ready,
                binding_transition: %{"phase" => "retiring"},
                reason: {:binding_repair, :mirror_cleanup_uncertain}
              }} = Cluster.status(Service, c.topology.id)

      assert {:error, :not_found} = Mirror.lookup(Service.Core, c.activation, "events")
      assert {:ok, %{pid: agent}} = Cluster.lookup(Service, c.ref)
      assert agent == c.agent
      assert Cluster.claims(Service) == c.claims
      assert {:ok, c.completed} == Cluster.operation(Service, c.completed.id)
      assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
    end

    {:ok, operation} = Cluster.stop(Service, c.topology.id, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :uncertain}} = Cluster.await(Service, operation.id)
    assert length(Cluster.claims(Service)) == 1
    stop_supervised!(Service)
    eventually(fn -> not Process.alive?(c.agent) end)

    # The uncertain cleanup keeps the owner alive. End that test process while
    # the activation record keeps its uncertain state.
    key = {Owner, "binding-repair", c.topology.id}
    owner = :global.whereis_name(key)
    assert is_pid(owner)
    assert :ok = DynamicSupervisor.terminate_child(Jido.Cluster.OwnerSupervisor, owner)
    eventually(fn -> :global.whereis_name(key) == :undefined end)
  end

  def hold_retirement(_, _, %{topology_id: id}, {id, observer}) do
    send(observer, {:retirement_waiting, self()})

    receive do
      :continue_retirement -> :ok
    after
      10_000 -> raise "Retirement barrier timed out"
    end
  end

  def hold_retirement(_, _, _, _), do: :ok

  defp lose_bridge(c) do
    monitor = Process.monitor(c.mirror)
    Process.exit(c.old.components.bridge, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 5000
    for pid <- [c.mirror | Map.values(c.old.components)], do: refute(Process.alive?(pid))
    assert Process.alive?(c.agent)
  end

  defp repair(c) do
    assert :ok = Cluster.reconcile(Service)
    ready(c)
  end

  defp ready(c) do
    eventually(fn ->
      not Cluster.status(Service).recovering and
        match?({:ok, %{binding_readiness: :ready, binding_transition: nil}}, Cluster.status(Service, c.topology.id))
    end)
  end

  defp publish(c, id, expected) do
    signal = Jido.Signal.new!(%{id: id, type: "counter.changed", source: "/repair-test", data: %{}})
    assert {:ok, _} = Cluster.publish(Service, c.topology.id, :events, signal)
    eventually(fn -> Enum.map(Jido.AgentServer.snapshot(c.agent).agent.state.events, & &1.id) == expected end)
  end

  defp stop(c) do
    {:ok, mirror} = Mirror.lookup(Service.Core, c.activation, "events")
    components = Mirror.status(mirror).components
    {:ok, operation} = Cluster.stop(Service, c.topology.id, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    for pid <- [c.agent, mirror | Map.values(components)], do: refute(Process.alive?(pid))
    assert [] = Cluster.claims(Service)
  end
end
