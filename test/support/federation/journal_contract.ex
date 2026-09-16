defmodule JidoCluster.Test.Federation.JournalContract do
  @moduledoc false
  use Jido.Cluster, otp_app: :jido_cluster, namespace: "federation-backend"
  import ExUnit.Assertions
  import JidoCluster.Test.Eventually
  alias Jido.Cluster
  alias Jido.Cluster.Federation.Mirror
  alias JidoCluster.Test.Federation.{DeclaredTopology, Subscriber}

  def exercise_bound(adapter) do
    base = DeclaredTopology.new!(id: "binding-bound")
    [agent] = base.definition.agents
    agents = for n <- 1..8, do: %{agent | key: "listener-#{n}"}
    channels = for n <- 1..8, do: %{"key" => "events-#{n}", "types" => ["counter.changed"]}

    bindings =
      for agent <- agents,
          channel <- channels,
          do: %{"agent" => agent.key, "channel" => channel["key"], "required" => true}

    metadata = %{
      "jido.cluster.requirements" => Map.new(agents, &{&1.key, ["compute"]}),
      "jido.cluster.federation" => %{"version" => 1, "channels" => channels, "bindings" => bindings}
    }

    {:ok, definition} = Jido.Topology.new(%{base.definition | agents: agents, metadata: metadata})
    {:ok, topology} = Jido.Topology.instantiate(definition, id: base.id)

    opts = [
      journal: adapter,
      namespace: "federation-bound",
      registry: %{
        "schema/v1" => {:schema, topology.definition.schema},
        "subscriber/v1" => {:agent, Subscriber},
        "node" => {:atom, :node}
      },
      pools: [workers: [hosts: [%{node: node(), capacity: 8, labels: ["compute"], available: true}]]]
    ]

    with_instance(opts, fn ->
      {:ok, op} = Cluster.deploy(__MODULE__, topology, request_id: Cluster.request_id(__MODULE__))
      assert {:ok, %{phase: :completed}} = Cluster.await(__MODULE__, op.id)
      {:ok, %{activation: activation, binding_intent: intent}} = Cluster.status(__MODULE__, topology.id)
      assert length(intent["bindings"]) == 64
      assert length(intent["mirrors"]) == 8
      assert intent["phase"] == "ready"
      {:ok, journal} = Cluster.Journal.open(adapter, {"federation-bound", "default"})
      bytes = byte_size(journal.expected)
      assert bytes < Cluster.Journal.limits().admission_bytes

      children =
        Enum.flat_map(channels, fn channel ->
          {:ok, mirror} = Mirror.lookup(__MODULE__.Core, activation, channel["key"])
          status = Mirror.status(mirror)
          assert length(status.bindings) == 8
          assert Enum.all?(status.bindings, & &1.ready)
          [mirror | Map.values(status.components)]
        end)

      {:ok, stop} = Cluster.stop(__MODULE__, topology.id, request_id: Cluster.request_id(__MODULE__))
      assert {:ok, %{phase: :completed}} = Cluster.await(__MODULE__, stop.id)
      for pid <- children, do: refute(Process.alive?(pid))
      assert %{active: 0} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(__MODULE__.Core))
      assert Cluster.claims(__MODULE__) == []
      %{bytes: bytes, bindings: 64}
    end)
  end

  def exercise(adapter, backend \\ nil) do
    topology = DeclaredTopology.new!(id: "backend-listener")

    opts = [
      journal: adapter,
      agent_persistence: adapter,
      registry: %{
        "schema/v1" => {:schema, topology.definition.schema},
        "subscriber/v1" => {:agent, Subscriber},
        "node" => {:atom, :node}
      },
      pools: [workers: [hosts: [%{node: node(), capacity: 1, labels: ["compute"], available: true}]]]
    ]

    {token, operation, ref, old_agent, old_mirror, old_intent} =
      with_instance(opts, fn ->
        token = Cluster.request_id(__MODULE__)
        {:ok, operation} = Cluster.deploy(__MODULE__, topology, request_id: token)
        assert {:ok, %{phase: :completed}} = Cluster.await(__MODULE__, operation.id)
        {:ok, ref} = Cluster.ref(__MODULE__, topology.id, :listener)
        {:ok, %{pid: agent}} = Cluster.lookup(__MODULE__, ref)
        {:ok, %{activation: activation, binding_intent: intent}} = Cluster.status(__MODULE__, topology.id)
        {:ok, mirror} = Mirror.lookup(__MODULE__.Core, activation, "events")
        assert intent["phase"] == "ready"
        publish(topology.id, agent, "before", ["before"])
        {token, operation, ref, agent, mirror, intent}
      end)

    refute Process.alive?(old_agent)
    refute Process.alive?(old_mirror)
    if backend, do: assert({:ok, _} = backend.restart())

    with_instance(opts, fn ->
      assert Cluster.status(__MODULE__).status == :reconciliation_required
      assert %{active: 0} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(__MODULE__.Core))
      assert :ok = Cluster.reconcile(__MODULE__)

      eventually(fn ->
        match?({:ok, %{binding_readiness: :ready, recovery: :idle}}, Cluster.status(__MODULE__, topology.id))
      end)

      {:ok, %{pid: agent}} = Cluster.lookup(__MODULE__, ref)
      assert agent != old_agent
      {:ok, %{binding_intent: intent}} = Cluster.status(__MODULE__, topology.id)
      assert intent["phase"] == "ready"
      assert intent["revision"] == old_intent["revision"] + 1
      assert hd(intent["bindings"])["id"] == hd(old_intent["bindings"])["id"]
      refute hd(intent["bindings"])["incarnation"] == hd(old_intent["bindings"])["incarnation"]
      assert events(agent) == ["before"]
      publish(topology.id, agent, "after", ["before", "after"])
      assert {:ok, %{id: id, phase: :completed}} = Cluster.deploy(__MODULE__, topology, request_id: token)
      assert id == operation.id
      {:ok, stop} = Cluster.stop(__MODULE__, topology.id, request_id: Cluster.request_id(__MODULE__))
      assert {:ok, %{phase: :completed}} = Cluster.await(__MODULE__, stop.id)
      refute Process.alive?(agent)
      assert Cluster.claims(__MODULE__) == []
    end)

    with_instance(opts, fn ->
      assert {:ok, %{desired: :stopped, binding_intent: %{"phase" => "stopped"}}} =
               Cluster.status(__MODULE__, topology.id)

      assert Cluster.status(__MODULE__).status == :ready
      assert %{active: 0} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(__MODULE__.Core))
      assert Cluster.claims(__MODULE__) == []
    end)

    :ok
  end

  defp publish(id, agent, signal_id, expected) do
    signal = Jido.Signal.new!(%{id: signal_id, type: "counter.changed", source: "/backend-federation", data: %{}})
    assert {:ok, _} = Cluster.publish(__MODULE__, id, :events, signal)
    eventually(fn -> events(agent) == expected end)
  end

  defp events(agent), do: Enum.map(Jido.AgentServer.snapshot(agent).agent.state.events, & &1.id)

  defp with_instance(opts, run) do
    {:ok, pid} = DynamicSupervisor.start_child(JidoCluster.Test.Supervisor, {__MODULE__, opts})

    try do
      run.()
    after
      assert :ok = DynamicSupervisor.terminate_child(JidoCluster.Test.Supervisor, pid)
      refute Process.alive?(pid)
    end
  end
end
