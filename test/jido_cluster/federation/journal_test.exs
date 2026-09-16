defmodule JidoCluster.Federation.JournalTest do
  use ExUnit.Case, async: false
  import JidoCluster.Test.Eventually
  alias Jido.Cluster
  alias Jido.Cluster.Federation.Mirror
  alias Jido.Cluster.Instance.Service, as: InstanceService
  alias JidoCluster.Test.Federation.{DeclaredTopology, Subscriber}
  alias JidoCluster.Test.JournalAdapter

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "federation-journal"
  end

  setup do
    adapter = start_supervised!(JournalAdapter)
    topology = DeclaredTopology.new!(id: "journal-listener")

    opts = [
      journal: {JournalAdapter, server: adapter},
      registry: %{
        "schema/v1" => {:schema, topology.definition.schema},
        "subscriber/v1" => {:agent, Subscriber},
        "node" => {:atom, :node}
      },
      pools: [workers: [hosts: [%{node: node(), capacity: 1, labels: ["compute"], available: true}]]]
    ]

    start_supervised!({Service, opts})
    %{adapter: adapter, topology: topology, opts: opts}
  end

  test "attachment intent is stored before mirrors and completion after attachment", c do
    arm(c, "attaching", {:hold, self()})
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert_receive {:journal_written, caller, token}, 5000
    on_exit(fn -> send(caller, {:release, token}) end)
    stored = deployment(c)
    intent = stored["federation"]
    assert intent["phase"] == "attaching"
    assert [%{"host" => host, "incarnation" => incarnation, "path" => ["listener"]}] = intent["bindings"]
    assert host == Atom.to_string(node())
    assert is_binary(incarnation)
    activation = activation(stored)
    assert {:error, :not_found} = Mirror.lookup(Service.Core, activation, "events")
    assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
    arm(c, "ready", {:hold, self()})
    send(caller, {:release, token})
    assert_receive {:journal_written, caller, token}, 5000
    on_exit(fn -> send(caller, {:release, token}) end)
    assert deployment(c)["phase"] == "accepted"
    assert deployment(c)["federation"]["phase"] == "ready"
    assert {:ok, mirror} = Mirror.lookup(Service.Core, activation, "events")
    assert Mirror.status(mirror).binding_readiness == :ready
    send(caller, {:release, token})
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    assert {:ok, %{binding_intent: %{"phase" => "ready"}}} = Cluster.status(Service, c.topology.id)

    assert {:error, :stale_binding_intent} =
             InstanceService.call(
               Service,
               {:federation_attaching, c.topology.id, activation, %{"listener" => node()}, 1}
             )

    stop(c)
  end

  test "an unknown attachment intent starts no mirror and recovery advances the binding revision", c do
    arm(c, "attaching", :commit_then_lose)
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert {:error, :journal_unavailable} = Cluster.await(Service, operation.id)
    old = deployment(c)
    assert {:error, :not_found} = Mirror.lookup(Service.Core, activation(old), "events")
    {:ok, ref} = Cluster.ref(Service, c.topology.id, :listener)
    {:ok, old_agent} = Jido.resolve_agent(Service.Core, ref)
    assert :ok = Cluster.reconcile(Service)
    ready(c)
    refute Process.alive?(old_agent)
    current = deployment(c)
    assert current["federation"]["revision"] == 1
    assert hd(current["federation"]["bindings"])["id"] == hd(old["federation"]["bindings"])["id"]

    assert {:error, :stale_binding_intent} =
             InstanceService.call(
               Service,
               {:federation_attaching, c.topology.id, activation(old), %{"listener" => node()}, 0}
             )

    assert {:ok, %{phase: :completed}} = Cluster.operation(Service, operation.id)
    stop(c)
  end

  test "an unknown binding completion cannot report a completed deployment", c do
    arm(c, "ready", :commit_then_lose)
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert {:error, :journal_unavailable} = Cluster.await(Service, operation.id)
    old = deployment(c)
    assert old["phase"] == "accepted"
    assert old["federation"]["phase"] == "ready"
    {:ok, mirror} = Mirror.lookup(Service.Core, activation(old), "events")
    assert Mirror.status(mirror).binding_readiness == :ready
    assert {:error, :journal_unavailable} = Cluster.publish(Service, c.topology.id, :events, signal())
    assert :ok = Cluster.reconcile(Service)
    ready(c)
    refute Process.alive?(mirror)
    assert {:ok, %{phase: :completed}} = Cluster.operation(Service, operation.id)
    stop(c)
  end

  test "stop records detach before cleanup and stopped intent survives full service restart", c do
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    old = deployment(c)
    {:ok, mirror} = Mirror.lookup(Service.Core, activation(old), "events")
    token = Cluster.request_id(Service)
    arm(c, "detaching", {:hold, self()})
    task = Task.async(fn -> Cluster.stop(Service, c.topology.id, request_id: token) end)
    assert_receive {:journal_written, caller, held}, 5000
    on_exit(fn -> send(caller, {:release, held}) end)
    assert deployment(c)["desired"] == "stopped"
    assert Process.alive?(mirror)
    send(caller, {:release, held})
    {:ok, stopped} = Task.await(task)
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, stopped.id)
    refute Process.alive?(mirror)
    assert deployment(c)["federation"]["phase"] == "stopped"

    assert {:error, :stale_binding_intent} =
             InstanceService.call(
               Service,
               {:federation_ready, c.topology.id, activation(old), old["federation"]}
             )

    assert :ok = stop_supervised(Service)
    start_supervised!({Service, c.opts})

    assert {:ok, %{binding_intent: %{"phase" => "stopped"}, agent_readiness: :stopped}} =
             Cluster.status(Service, c.topology.id)

    assert %{active: 0} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
    assert Cluster.claims(Service) == []
  end

  defp arm(c, phase, mode) do
    predicate = fn bytes ->
      case Jason.decode!(bytes)["record"]["deployments"] do
        [%{"federation" => %{"phase" => ^phase}}] -> true
        _ -> false
      end
    end

    :ok = JournalAdapter.when_write(c.adapter, predicate, mode)
  end

  defp deployment(c) do
    {:ok, journal} = Cluster.Journal.open({JournalAdapter, server: c.adapter}, {"federation-journal", "default"})
    hd(journal.record["deployments"])
  end

  defp activation(stored),
    do: Map.new(stored["activation"], fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp ready(c),
    do:
      eventually(fn ->
        match?({:ok, %{binding_readiness: :ready, recovery: :idle}}, Cluster.status(Service, c.topology.id))
      end)

  defp signal, do: Jido.Signal.new!(%{type: "counter.changed", source: "/journal-test", data: %{}})

  defp stop(c) do
    {:ok, operation} = Cluster.stop(Service, c.topology.id, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    assert Cluster.claims(Service) == []
    assert %{active: 0} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
  end
end
