defmodule JidoCluster.Distributed.FederationMovementTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster
  alias Jido.Cluster.Federation.Mirror
  alias JidoCluster.Test.Federation.{DeclaredTopology, Subscriber}
  alias JidoCluster.Test.{Instance, JournalAdapter}

  @tag cluster_nodes: 3
  test "journaled drain preserves subscriber state and revisions through a return to an earlier host", c do
    %{
      control: control,
      workers: workers,
      jido: jido,
      topology: topology,
      api: api,
      service: service,
      guards: guards,
      cores: cores
    } = setup_cluster(c)

    {:ok, deployed} = api.(:deploy, [topology, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [deployed.id])
    {:ok, ref} = api.(:ref, [topology.id, :listener])
    {:ok, %{pid: first}} = api.(:lookup, [ref])
    source = node(first)
    [target] = workers -- [source]
    {:ok, %{activation: activation, binding_intent: original}} = api.(:status, [topology.id])
    {:ok, first_mirror} = cluster_call(c.cluster, source, Mirror, :lookup, [jido, activation, "events"])
    old_status = cluster_call(c.cluster, source, Mirror, :status, [first_mirror])
    publish(c, api, topology.id, first, "before", ["before"])

    {:ok, moved} = api.(:drain, [source, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [moved.id, 10_000])
    {:ok, %{pid: second}} = api.(:lookup, [ref])
    assert node(second) == target
    refute cluster_call(c.cluster, source, Process, :alive?, [first])

    for pid <- [first_mirror | Map.values(old_status.components)],
        do: refute(cluster_call(c.cluster, source, Process, :alive?, [pid]))

    assert {:error, :not_found} = cluster_call(c.cluster, source, Mirror, :lookup, [jido, activation, "events"])

    assert {:ok, %{binding_transition: nil, binding_readiness: :ready, binding_intent: moved_intent}} =
             api.(:status, [topology.id])

    assert moved_intent["revision"] == 1
    assert hd(moved_intent["bindings"])["id"] == hd(original["bindings"])["id"]
    publish(c, api, topology.id, second, "after", ["before", "after"])

    assert {:ok, %{phase: :completed}} = api.(:enable_host, [source, [request_id: api.(:request_id, [])]])
    {:ok, returned} = api.(:drain, [target, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [returned.id, 10_000])
    {:ok, %{pid: third}} = api.(:lookup, [ref])
    assert node(third) == source
    refute cluster_call(c.cluster, target, Process, :alive?, [second])
    {:ok, current_mirror} = cluster_call(c.cluster, source, Mirror, :lookup, [jido, activation, "events"])
    current = cluster_call(c.cluster, source, Mirror, :status, [current_mirror])
    assert current.revision == 1

    assert {:error, :binding_target_changed} =
             cluster_call(c.cluster, source, Mirror, :attach, [current_mirror, ref, first])

    assert {:error, :operation_owner_mismatch} =
             cluster_call(c.cluster, control, Cluster.Deployment.Owner, :resource, [
               current.owner,
               :close,
               source,
               "events",
               1
             ])

    assert {:ok, %{binding_intent: %{"revision" => 2}}} = api.(:status, [topology.id])

    assert {:error, :resource_revision_changed} =
             cluster_call(c.cluster, source, Mirror, :stop_generation, [jido, activation, current.owner, "events", 0])

    assert {:ok, ^current_mirror} = cluster_call(c.cluster, source, Mirror, :lookup, [jido, activation, "events"])
    publish(c, api, topology.id, third, "returned", ["before", "after", "returned"])
    assert [%{host: ^source, state: :active}] = api.(:claims, [])
    assert {:ok, %{phase: :completed}} = api.(:operation, [deployed.id])
    {:ok, stop} = api.(:stop, [topology.id, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [stop.id])
    assert [] = api.(:claims, [])

    for pid <- [third, current_mirror | Map.values(current.components)],
        do: refute(cluster_call(c.cluster, source, Process, :alive?, [pid]))

    stop(c, control, service)
    for {host, pid} <- guards ++ cores, do: stop(c, host, pid)
  end

  for phase <- ["retiring", "retired", "attaching"] do
    @tag cluster_nodes: 3
    test "an unknown #{phase} write blocks dependent movement work until explicit recovery", c do
      phase = unquote(phase)
      f = setup_cluster(c, true)
      api = f.api
      {:ok, deployed} = api.(:deploy, [f.topology, [request_id: api.(:request_id, [])]])
      assert {:ok, %{phase: :completed}} = api.(:await, [deployed.id])
      {:ok, ref} = api.(:ref, [f.topology.id, :listener])
      {:ok, %{pid: original}} = api.(:lookup, [ref])
      source = node(original)
      [target] = f.workers -- [source]
      {:ok, %{activation: activation}} = api.(:status, [f.topology.id])
      {:ok, mirror} = cluster_call(c.cluster, source, Mirror, :lookup, [f.jido, activation, "events"])
      publish(c, api, f.topology.id, original, "before", ["before"])
      field = if phase == "attaching", do: "federation", else: "federation_transition"
      path = ["record", "deployments", 0, field, "phase"]

      assert :ok =
               cluster_call(c.cluster, f.control, JidoCluster.Test.JournalAdapter, :when_path, [
                 f.faults,
                 path,
                 phase,
                 :commit_then_lose
               ])

      token = api.(:request_id, [])
      result = api.(:drain, [source, [request_id: token]])

      if phase == "retiring" do
        assert {:error, {:journal_write_failed, _}} = result
      else
        assert {:ok, op} = result
        assert {:error, :journal_unavailable} = api.(:await, [op.id, 10_000])
      end

      assert %{status: :journal_unavailable} = api.(:status, [])
      assert length(api.(:claims, [])) == 2
      assert cluster_call(c.cluster, source, Process, :alive?, [original]) == (phase != "attaching")
      assert cluster_call(c.cluster, source, Process, :alive?, [mirror]) == (phase == "retiring")

      count = if phase == "attaching", do: 1, else: 0

      assert %{active: ^count} =
               cluster_call(c.cluster, target, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(f.jido)])

      assert {:error, :not_found} = cluster_call(c.cluster, target, Mirror, :lookup, [f.jido, activation, "events"])

      {:ok, journal} = cluster_call(c.cluster, f.control, Cluster.Journal, :open, [f.journal, {f.namespace, "default"}])
      [stored] = journal.record["deployments"]
      assert stored[field]["phase"] == phase
      assert stored["federation_transition"]["from"] == %{"listener" => Atom.to_string(source)}
      assert stored["selected"] == %{"listener" => Atom.to_string(target)}
      assert :ok = api.(:reconcile, [])
      eventually(fn -> match?({:ok, %{binding_readiness: :ready, recovery: :idle}}, api.(:status, [f.topology.id])) end)
      {:ok, %{pid: recovered}} = api.(:lookup, [ref])
      assert node(recovered) == target
      refute cluster_call(c.cluster, source, Process, :alive?, [original])
      assert {:ok, %{phase: :completed}} = api.(:drain, [source, [request_id: token]])
      publish(c, api, f.topology.id, recovered, "after", ["before", "after"])
      assert [%{host: ^target, state: :active}] = api.(:claims, [])
      {:ok, stopped} = api.(:stop, [f.topology.id, [request_id: api.(:request_id, [])]])
      assert {:ok, %{phase: :completed}} = api.(:await, [stopped.id])
      assert [] = api.(:claims, [])
      refute cluster_call(c.cluster, target, Process, :alive?, [recovered])
      stop(c, f.control, f.service)
      stop(c, f.control, f.faults)
      for {host, pid} <- f.guards ++ f.cores, do: stop(c, host, pid)
    end
  end

  for phase <- ["retiring", "retired", "attaching", "ready"] do
    @tag cluster_nodes: 3
    test "bridge lifecycle respects the held #{phase} movement receipt", c do
      phase = unquote(phase)
      f = setup_cluster(c, true)
      api = f.api
      {:ok, deployed} = api.(:deploy, [f.topology, [request_id: api.(:request_id, [])]])
      assert {:ok, %{phase: :completed}} = api.(:await, [deployed.id])
      {:ok, ref} = api.(:ref, [f.topology.id, :listener])
      {:ok, %{pid: original}} = api.(:lookup, [ref])
      source = node(original)
      [target] = f.workers -- [source]
      {:ok, %{activation: activation}} = api.(:status, [f.topology.id])
      publish(c, api, f.topology.id, original, "before", ["before"])
      field = if phase in ["retiring", "retired"], do: "federation_transition", else: "federation"
      path = ["record", "deployments", 0, field, "phase"]

      assert :ok = cluster_call(c.cluster, f.control, JournalAdapter, :when_path, [f.faults, path, phase, :manual_hold])
      token = api.(:request_id, [])
      assert {:ok, _} = cluster_call(c.cluster, f.control, JournalAdapter, :start_drain, [Instance, source, token])
      eventually(fn -> cluster_call(c.cluster, f.control, JournalAdapter, :waiting, [f.faults]) end)

      bridge_at_boundary(c, f, activation, source, target, phase)
      assert :ok = cluster_call(c.cluster, f.control, JournalAdapter, :release, [f.faults])
      {:ok, moved} = api.(:drain, [source, [request_id: token]])
      assert {:ok, %{phase: :completed}} = api.(:await, [moved.id, 10_000])
      {:ok, %{pid: current}} = api.(:lookup, [ref])
      assert node(current) == target
      refute cluster_call(c.cluster, source, Process, :alive?, [original])

      if phase == "ready" do
        assert {:ok, %{agent_readiness: :ready, binding_readiness: readiness}} = api.(:status, [f.topology.id])
        refute readiness == :ready
        assert :ok = api.(:reconcile, [])
        eventually(fn -> not api.(:status, []).recovering end)
        assert {:ok, %{pid: ^current}} = api.(:lookup, [ref])
      end

      assert {:ok, %{binding_readiness: :ready, binding_transition: nil}} = api.(:status, [f.topology.id])
      assert [%{host: ^target, state: :active}] = api.(:claims, [])
      assert {:ok, %{phase: :completed}} = api.(:operation, [moved.id])
      publish(c, api, f.topology.id, current, "after", ["before", "after"])
      {:ok, stopped} = api.(:stop, [f.topology.id, [request_id: api.(:request_id, [])]])
      assert {:ok, %{phase: :completed}} = api.(:await, [stopped.id])
      assert [] = api.(:claims, [])
      refute cluster_call(c.cluster, target, Process, :alive?, [current])
      stop(c, f.control, f.service)
      stop(c, f.control, f.faults)
      for {host, pid} <- f.guards ++ f.cores, do: stop(c, host, pid)
    end
  end

  defp bridge_at_boundary(c, f, activation, source, target, phase) when phase in ["retiring", "ready"] do
    host = if phase == "retiring", do: source, else: target
    {:ok, mirror} = cluster_call(c.cluster, host, Mirror, :lookup, [f.jido, activation, "events"])
    %{components: components} = cluster_call(c.cluster, host, Mirror, :status, [mirror])
    assert true = cluster_call(c.cluster, host, Process, :exit, [components.bridge, :kill])

    eventually(fn ->
      Enum.all?([mirror | Map.values(components)], &(not cluster_call(c.cluster, host, Process, :alive?, [&1])))
    end)
  end

  defp bridge_at_boundary(c, f, activation, source, target, _phase) do
    # No bridge is live between confirmed retirement and target setup.
    for host <- [f.control, source, target] do
      assert {:error, :not_found} = cluster_call(c.cluster, host, Mirror, :lookup, [f.jido, activation, "events"])
    end
  end

  defp setup_cluster(c, fault? \\ false) do
    [control | workers] = c.cluster.nodes
    table = shared_table(c.cluster, c.cluster.nodes)
    persistence = {Jido.Persistence.Mnesia, table: table}
    jido = __MODULE__.Core
    namespace = "binding-movement/#{Jido.generate_id()}"

    cores =
      for host <- c.cluster.nodes,
          do: {host, start(c, host, {Jido, name: jido, namespace: namespace, persistence: persistence})}

    guards = for host <- workers, do: {host, start(c, host, {Cluster.HostRuntime, jido: jido})}
    topology = DeclaredTopology.new!(id: "moving-listener")

    registry = %{
      "schema/v1" => {:schema, topology.definition.schema},
      "subscriber/v1" => {:agent, Subscriber},
      "node" => {:atom, :node}
    }

    hosts = for host <- workers, do: %{node: host, labels: ["compute"], capacity: 1, available: true}

    faults = if fault?, do: start(c, control, {JidoCluster.Test.JournalAdapter, []})
    journal = if faults, do: {JidoCluster.Test.JournalAdapter, server: faults}, else: persistence

    service =
      start(
        c,
        control,
        {Instance, jido: jido, journal: journal, registry: registry, pools: [workers: [hosts: hosts]]}
      )

    api = fn fun, args -> cluster_call(c.cluster, control, Cluster, fun, [Instance | args]) end

    %{
      control: control,
      workers: workers,
      jido: jido,
      topology: topology,
      api: api,
      service: service,
      guards: guards,
      cores: cores,
      faults: faults,
      journal: journal,
      namespace: namespace
    }
  end

  defp publish(c, api, id, agent, signal_id, expected) do
    signal = Jido.Signal.new!(%{id: signal_id, type: "counter.changed", source: "/movement-test", data: %{}})
    assert {:ok, _} = api.(:publish, [id, :events, signal])

    eventually(fn ->
      snapshot = cluster_call(c.cluster, node(agent), Jido.AgentServer, :snapshot, [agent])
      Enum.map(snapshot.agent.state.events, & &1.id) == expected
    end)
  end

  defp start(c, host, child) do
    assert {:ok, pid} =
             cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, child])

    pid
  end

  defp stop(c, host, pid) do
    assert :ok =
             cluster_call(c.cluster, host, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, pid])

    refute cluster_call(c.cluster, host, Process, :alive?, [pid])
  end
end
