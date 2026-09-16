defmodule JidoCluster.Distributed.HostProviderServiceTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster
  alias Jido.Cluster.HostProvider.{Resource, Step}
  alias Jido.Cluster.HostRuntime
  alias JidoCluster.Test.Bedrock
  alias JidoCluster.Test.Federation.{DeclaredTopology, Subscriber}
  alias JidoCluster.Test.{HostProvider, Instance, JournalAdapter}

  test "acquisition precedes admission and release waits for Agent and binding cleanup", c do
    f = start(c)
    assert {:error, {:no_capacity, "listener"}} = f.api.(:plan, [f.topology])
    token = f.api.(:request_id, [])
    {:ok, acquired} = f.api.(:acquire_host, [f.worker, [request_id: token]])
    assert {:ok, %{phase: :completed}} = f.api.(:await, [acquired.id])
    assert {:ok, %{id: id}} = f.api.(:acquire_host, [f.worker, [request_id: token]])
    assert id == acquired.id
    assert {:ok, %{admission: :open, session: %{phase: :ready}}} = f.api.(:host_status, [f.worker])
    {:ok, deployed} = f.api.(:deploy, [f.topology, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = f.api.(:await, [deployed.id])
    {:ok, ref} = f.api.(:ref, [f.topology.id, :listener])
    {:ok, %{pid: agent}} = f.api.(:lookup, [ref])
    signal = Jido.Signal.new!(%{id: "before-release", type: "counter.changed", source: "/provider-service", data: %{}})
    assert {:ok, _} = f.api.(:publish, [f.topology.id, :events, signal])

    eventually(fn ->
      cluster_call(c.cluster, f.worker, Jido.AgentServer, :snapshot, [agent]).agent.state.events != []
    end)

    release_token = f.api.(:request_id, [])
    {:ok, release} = f.api.(:release_host, [f.worker, [request_id: release_token]])
    assert {:ok, %{phase: :uncertain, reason: :claims_retained}} = f.api.(:await, [release.id])
    assert {:error, :host_release_exists} = f.api.(:release_host, [f.worker, [request_id: f.api.(:request_id, [])]])
    assert [_] = resources(c, f)
    assert [_] = f.api.(:claims, [])
    assert cluster_call(c.cluster, f.worker, Process, :alive?, [agent])
    assert {:ok, %{admission: :closed}} = f.api.(:host_status, [f.worker])
    {:ok, stopped} = f.api.(:stop, [f.topology.id, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = f.api.(:await, [stopped.id])
    refute cluster_call(c.cluster, f.worker, Process, :alive?, [agent])
    recover(f)
    assert {:ok, %{phase: :completed, id: id}} = f.api.(:release_host, [f.worker, [request_id: release_token]])
    assert id == release.id
    assert [] = resources(c, f)
    assert {:ok, %{phase: :completed}} = f.api.(:operation, [acquired.id])
    finish(c, f)
  end

  test "a lost acquire reply survives service restart and adopts only its original step", c do
    f = start(c)
    assert :ok = cluster_call(c.cluster, f.control, HostProvider, :mode, [f.provider, :lose_acquire_reply])
    token = f.api.(:request_id, [])
    {:ok, acquired} = f.api.(:acquire_host, [f.worker, [request_id: token]])
    assert {:ok, %{phase: :uncertain}} = f.api.(:await, [acquired.id])
    assert [resource] = resources(c, f)
    crash(c, f)
    f = %{f | service: child(c, f.control, Supervisor.child_spec({Instance, f.options}, restart: :temporary))}
    assert %{status: :reconciliation_required} = f.api.(:status, [])
    recover(f)
    assert {:ok, %{id: id, phase: :completed}} = f.api.(:acquire_host, [f.worker, [request_id: token]])
    assert id == acquired.id
    assert [^resource] = resources(c, f)
    calls = cluster_call(c.cluster, f.control, HostProvider, :calls, [f.provider])
    assert Enum.count(calls, &match?({:acquire, _}, &1)) == 1
    release(c, f)
    finish(c, f)
  end

  test "the deletion journal receipt precedes the provider effect and closes re-registration", c do
    f = start(c)
    acquire(f)
    path = ["record", "host_sessions", 0, "phase"]

    assert :ok =
             cluster_call(c.cluster, f.control, JournalAdapter, :when_path, [f.journal, path, "deleting", :manual_hold])

    {:ok, operation} = f.api.(:release_host, [f.worker, [request_id: f.api.(:request_id, [])]])
    eventually(fn -> cluster_call(c.cluster, f.control, JournalAdapter, :waiting, [f.journal]) end)
    assert [_] = resources(c, f)
    calls = cluster_call(c.cluster, f.control, HostProvider, :calls, [f.provider])
    refute Enum.any?(calls, &match?({:release, _}, &1))
    status = cluster_call(c.cluster, f.worker, HostRuntime, :status, [HostRuntime.name(f.jido)])
    assert status.allocations["default"].retiring_step != nil
    assert :ok = cluster_call(c.cluster, f.control, JournalAdapter, :release, [f.journal])
    assert {:ok, %{phase: :completed}} = f.api.(:await, [operation.id])
    assert [] = resources(c, f)
    finish(c, f)
  end

  test "absent inspection cannot close an unknown creation that takes effect after restart", c do
    f = start(c)
    assert :ok = cluster_call(c.cluster, f.control, HostProvider, :mode, [f.provider, :delay_acquire])
    {:ok, acquire} = f.api.(:acquire_host, [f.worker, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :uncertain}} = f.api.(:await, [acquire.id])
    assert {:ok, %{session: %{step: step, attempted: true, resource: nil}}} = f.api.(:host_status, [f.worker])
    token = f.api.(:request_id, [])
    {:ok, release} = f.api.(:release_host, [f.worker, [request_id: token]])
    assert {:ok, %{phase: :uncertain, reason: :acquisition_unresolved}} = f.api.(:await, [release.id])
    assert [] = resources(c, f)
    crash(c, f)
    f = %{f | service: child(c, f.control, Supervisor.child_spec({Instance, f.options}, restart: :temporary))}
    recover(f)
    assert {:ok, %{phase: :uncertain, reason: :acquisition_unresolved}} = f.api.(:operation, [release.id])
    assert {:ok, %{admission: :closed, session: %{step: ^step, resource: nil}}} = f.api.(:host_status, [f.worker])
    assert {:ok, late} = cluster_call(c.cluster, f.control, HostProvider, :complete_acquire, [f.provider, step])
    assert [^late] = resources(c, f)
    recover(f)
    assert {:ok, %{phase: :completed, id: id}} = f.api.(:release_host, [f.worker, [request_id: token]])
    assert id == release.id
    assert {:ok, %{session: %{phase: :released, resource: ^late}}} = f.api.(:host_status, [f.worker])
    assert {:ok, %{phase: :failed, reason: :released_before_ready}} = f.api.(:operation, [acquire.id])
    calls = cluster_call(c.cluster, f.control, HostProvider, :calls, [f.provider])
    assert [{:acquire, ^step}] = Enum.filter(calls, &match?({:acquire, _}, &1))
    assert [{:release, ^late}] = Enum.filter(calls, &match?({:release, _}, &1))
    finish(c, f)
  end

  test "an incompatible prepared runtime starts no Agent and retains owned cleanup intent", c do
    f = start(c, "wrong-worker-namespace")
    {:ok, operation} = f.api.(:acquire_host, [f.worker, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :uncertain, reason: {:incompatible, :namespace}}} = f.api.(:await, [operation.id])
    assert {:error, {:no_capacity, "listener"}} = f.api.(:plan, [f.topology])

    assert %{active: 0} =
             cluster_call(c.cluster, f.worker, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(f.jido)])

    release(c, f)
    assert {:ok, %{phase: :failed, reason: :released_before_ready}} = f.api.(:operation, [operation.id])
    finish(c, f)
  end

  test "a compatible runtime without the acquired boot identity cannot open admission", c do
    f = start(c)
    child(c, f.worker, {HostRuntime, jido: f.jido})
    {:ok, operation} = f.api.(:acquire_host, [f.worker, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :uncertain, reason: {:incompatible, :provider_step}}} = f.api.(:await, [operation.id])
    assert {:ok, %{admission: :closed}} = f.api.(:host_status, [f.worker])
    assert {:error, {:no_capacity, "listener"}} = f.api.(:plan, [f.topology])
    release(c, f)
    finish(c, f)
  end

  test "a lost deletion receipt blocks the provider until journal recovery", c do
    f = start(c)
    acquire(f)
    path = ["record", "host_sessions", 0, "phase"]

    assert :ok =
             cluster_call(c.cluster, f.control, JournalAdapter, :when_path, [
               f.journal,
               path,
               "deleting",
               :commit_then_lose
             ])

    token = f.api.(:request_id, [])
    {:ok, operation} = f.api.(:release_host, [f.worker, [request_id: token]])
    assert {:error, :journal_unavailable} = f.api.(:await, [operation.id])
    assert [_] = resources(c, f)
    calls = cluster_call(c.cluster, f.control, HostProvider, :calls, [f.provider])
    refute Enum.any?(calls, &match?({:release, _}, &1))
    recover(f)
    assert {:ok, %{phase: :completed, id: id}} = f.api.(:release_host, [f.worker, [request_id: token]])
    assert id == operation.id
    release(c, f)
    finish(c, f)
  end

  test "provider uncertainty blocks a recorded deployment replacement", c do
    f = start(c)
    acquire(f)
    {:ok, deployed} = f.api.(:deploy, [f.topology, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = f.api.(:await, [deployed.id])
    {:ok, ref} = f.api.(:ref, [f.topology.id, :listener])
    {:ok, %{pid: previous}} = f.api.(:lookup, [ref])
    crash(c, f)
    f = %{f | service: child(c, f.control, Supervisor.child_spec({Instance, f.options}, restart: :temporary))}
    assert :ok = cluster_call(c.cluster, f.control, HostProvider, :mode, [f.provider, :inspect_unavailable])
    recover(f)
    assert {:ok, %{admission: :closed}} = f.api.(:host_status, [f.worker])
    assert {:ok, %{reason: {:host_provider_pending, [worker]}}} = f.api.(:status, [f.topology.id])
    assert worker == f.worker
    refute cluster_call(c.cluster, f.worker, Process, :alive?, [previous])

    assert %{active: 0} =
             cluster_call(c.cluster, f.worker, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(f.jido)])

    recover(f)
    assert {:ok, %{pid: current}} = f.api.(:lookup, [ref])
    assert current != previous
    {:ok, stopped} = f.api.(:stop, [f.topology.id, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = f.api.(:await, [stopped.id])
    release(c, f)
    finish(c, f)
  end

  test "host recovery remains available after its completed operation expires", c do
    f = start(c)
    acquire(f)

    for _ <- 1..63 do
      assert {:ok, _} = f.api.(:enable_host, [f.worker, [request_id: f.api.(:request_id, [])]])
    end

    assert %{epoch: 1} = f.api.(:request_id, [])
    crash(c, f)
    f = %{f | service: child(c, f.control, Supervisor.child_spec({Instance, f.options}, restart: :temporary))}
    assert :ok = cluster_call(c.cluster, f.control, HostProvider, :mode, [f.provider, :inspect_unavailable])
    recover(f)
    assert {:ok, %{admission: :closed, session: %{phase: :uncertain}}} = f.api.(:host_status, [f.worker])
    recover(f)
    assert {:ok, %{admission: :open, session: %{phase: :ready}}} = f.api.(:host_status, [f.worker])
    release(c, f)
    finish(c, f)
  end

  test "borrowed capacity needs no boot stamp and survives release", c do
    f = start(c, nil, :borrowed)
    guard = child(c, f.worker, {HostRuntime, jido: f.jido})
    path = ["record", "host_sessions", 0, "phase"]

    assert :ok =
             cluster_call(c.cluster, f.control, JournalAdapter, :when_path, [f.journal, path, "planned", :manual_hold])

    caller = Task.async(fn -> f.api.(:acquire_host, [f.worker, [request_id: f.api.(:request_id, [])]]) end)
    eventually(fn -> cluster_call(c.cluster, f.control, JournalAdapter, :waiting, [f.journal]) end)
    writes = cluster_call(c.cluster, f.control, JournalAdapter, :writes, [f.journal])
    {_, _, bytes} = List.last(writes)
    [record] = Jason.decode!(bytes)["record"]["host_sessions"]
    {:ok, step} = Step.from_record(record["step"])
    {:ok, resource} = cluster_call(c.cluster, f.control, HostProvider, :acquire, [step, [server: f.provider]])
    assert :ok = cluster_call(c.cluster, f.control, JournalAdapter, :release, [f.journal])
    {:ok, acquired} = Task.await(caller)
    assert {:ok, %{phase: :completed}} = f.api.(:await, [acquired.id])
    {:ok, released} = f.api.(:release_host, [f.worker, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = f.api.(:await, [released.id])
    assert {:ok, %{admission: :closed, session: %{phase: :retained}}} = f.api.(:host_status, [f.worker])
    assert [^resource] = resources(c, f)
    assert cluster_call(c.cluster, f.worker, Process, :alive?, [guard])
    calls = cluster_call(c.cluster, f.control, HostProvider, :calls, [f.provider])
    assert Enum.count(calls, &match?({:acquire, _}, &1)) == 1
    refute Enum.any?(calls, &match?({:release, _}, &1))
    assert :ok = cluster_call(c.cluster, f.control, HostProvider, :release, [resource, [server: f.provider]])
    finish(c, f)
  end

  test "a deletion receipt survives lost replies and the deleted host need not answer", c do
    f = start(c)
    acquire(f)
    assert :ok = cluster_call(c.cluster, f.control, HostProvider, :mode, [f.provider, :lose_release_and_inspection])
    token = f.api.(:request_id, [])
    {:ok, operation} = f.api.(:release_host, [f.worker, [request_id: token]])
    assert {:ok, %{phase: :uncertain, reason: {:release_inspection, :unavailable}}} = f.api.(:await, [operation.id])
    assert [] = resources(c, f)
    assert {:ok, %{session: %{phase: :deleting}}} = f.api.(:host_status, [f.worker])
    guard = cluster_call(c.cluster, f.worker, Process, :whereis, [HostRuntime.name(f.jido)])
    stop(c, f.worker, guard)
    crash(c, f)
    f = %{f | service: child(c, f.control, Supervisor.child_spec({Instance, f.options}, restart: :temporary))}
    recover(f)
    assert {:ok, %{phase: :completed, id: id}} = f.api.(:release_host, [f.worker, [request_id: token]])
    assert id == operation.id
    assert {:ok, %{session: %{phase: :released}}} = f.api.(:host_status, [f.worker])
    finish(c, f)
  end

  test "an unrelated caller cannot change a recorded host step", c do
    f = start(c)
    acquire(f)
    {:ok, %{session: session}} = f.api.(:host_status, [f.worker])

    assert {:error, :stale_host_task} =
             cluster_call(c.cluster, f.control, Cluster.Instance.Service, :call, [
               Instance,
               {:host_progress, f.worker, session}
             ])

    assert {:error, :stale_host_task} =
             cluster_call(c.cluster, f.control, Cluster.Instance.Service, :call, [
               Instance,
               {:host_recovery_result, f.worker, session.step.id, %{phase: :failed, reason: :forged}}
             ])

    assert {:ok, %{admission: :open, session: ^session}} = f.api.(:host_status, [f.worker])
    release(c, f)
    finish(c, f)
  end

  test "an unknown acceptance remains visible and starts no provider effect before recovery", c do
    f = start(c)
    path = ["record", "host_sessions", 0, "phase"]

    assert :ok =
             cluster_call(c.cluster, f.control, JournalAdapter, :when_path, [
               f.journal,
               path,
               "planned",
               :commit_then_lose
             ])

    token = f.api.(:request_id, [])
    assert {:error, {:journal_write_failed, _}} = f.api.(:acquire_host, [f.worker, [request_id: token]])

    assert {:ok,
            %{
              session: nil,
              pending_session: %{phase: :planned} = possible,
              admission: :closed,
              journal: :journal_unavailable
            }} = f.api.(:host_status, [f.worker])

    assert [] = resources(c, f)
    assert [] = cluster_call(c.cluster, f.control, HostProvider, :calls, [f.provider])
    recover(f)
    assert {:ok, %{session: %{step: step, phase: :ready}, pending_session: nil}} = f.api.(:host_status, [f.worker])
    assert step == possible.step
    assert {:ok, %{phase: :completed}} = f.api.(:acquire_host, [f.worker, [request_id: token]])
    release(c, f)
    finish(c, f)
  end

  @tag real_bedrock: true, tmp_dir: true, timeout: 90_000
  test "real Bedrock retains host identity through owner and repository restart", c do
    f = start(c)
    assert :ok = cluster_call(c.cluster, f.control, HostProvider, :mode, [f.provider, :lose_acquire_reply])
    token = f.api.(:request_id, [])
    {:ok, acquired} = f.api.(:acquire_host, [f.worker, [request_id: token]])
    assert {:ok, %{phase: :uncertain}} = f.api.(:await, [acquired.id])
    assert [resource] = resources(c, f)
    crash(c, f)
    assert {:ok, _} = cluster_call(c.cluster, f.control, Bedrock, :restart, [], 40_000)
    f = %{f | service: child(c, f.control, Supervisor.child_spec({Instance, f.options}, restart: :temporary))}
    recover(f)
    assert {:ok, %{phase: :completed, id: id}} = f.api.(:acquire_host, [f.worker, [request_id: token]])
    assert id == acquired.id
    assert [^resource] = resources(c, f)
    {:ok, deployed} = f.api.(:deploy, [f.topology, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = f.api.(:await, [deployed.id])
    {:ok, ref} = f.api.(:ref, [f.topology.id, :listener])
    {:ok, %{pid: previous}} = f.api.(:lookup, [ref])
    publish(c, f, previous, "before-restart", ["before-restart"])
    crash(c, f)
    assert {:ok, _} = cluster_call(c.cluster, f.control, Bedrock, :restart, [], 40_000)
    f = %{f | service: child(c, f.control, Supervisor.child_spec({Instance, f.options}, restart: :temporary))}
    recover(f)
    {:ok, %{pid: current}} = f.api.(:lookup, [ref])
    assert current != previous
    refute cluster_call(c.cluster, f.worker, Process, :alive?, [previous])
    publish(c, f, current, "after-restart", ["before-restart", "after-restart"])
    assert [^resource] = resources(c, f)
    calls = cluster_call(c.cluster, f.control, HostProvider, :calls, [f.provider])
    assert Enum.count(calls, &match?({:acquire, _}, &1)) == 1
    {:ok, stopped} = f.api.(:stop, [f.topology.id, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = f.api.(:await, [stopped.id])
    release(c, f)

    assert {:ok, journal} =
             cluster_call(c.cluster, f.control, Cluster.Journal, :open, [f.options[:journal], {f.namespace, "default"}])

    assert [%{"phase" => "released", "resource" => saved}] = journal.record["host_sessions"]
    assert saved == Resource.to_record(resource)
    finish(c, f)
  end

  defp start(c, worker_namespace \\ nil, ownership \\ :owned) do
    [control, worker] = c.cluster.nodes
    namespace = "provider-service/#{Jido.generate_id()}"
    jido = __MODULE__.Core
    {journal, persistence} = storage(c, control)

    cores =
      for host <- c.cluster.nodes,
          do:
            {host,
             child(
               c,
               host,
               {Jido,
                name: jido,
                namespace: if(host == worker, do: worker_namespace || namespace, else: namespace),
                persistence: persistence}
             )}

    provider = child(c, control, {HostProvider, []})
    topology = DeclaredTopology.new!(id: "provider-listener")

    options = [
      jido: jido,
      journal: if(is_pid(journal), do: {JournalAdapter, server: journal}, else: journal),
      registry: %{
        "schema/v1" => {:schema, topology.definition.schema},
        "subscriber/v1" => {:agent, Subscriber},
        "node" => {:atom, :node}
      },
      pools: [workers: [hosts: [%{node: worker, labels: ["compute"], capacity: 2, available: true}]]],
      host_providers: %{
        worker => [
          id: "fake-authority",
          adapter: {HostProvider, server: provider, host_runtime: {worker, [jido: jido]}},
          ownership: ownership
        ]
      }
    ]

    service = child(c, control, Supervisor.child_spec({Instance, options}, restart: :temporary))
    api = fn fun, args -> cluster_call(c.cluster, control, Cluster, fun, [Instance | args]) end

    %{
      control: control,
      worker: worker,
      jido: jido,
      namespace: namespace,
      cores: cores,
      provider: provider,
      journal: journal,
      topology: topology,
      options: options,
      service: service,
      api: api
    }
  end

  defp acquire(f) do
    {:ok, op} = f.api.(:acquire_host, [f.worker, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = f.api.(:await, [op.id])
  end

  defp storage(%{real_bedrock: true} = c, control) do
    on_exit(fn ->
      stop_node(c.cluster, control)
      File.rm_rf!(c.tmp_dir)
    end)

    assert {:ok, _} = cluster_call(c.cluster, control, Bedrock, :start, [c.tmp_dir], 40_000)
    table = shared_table(c.cluster, c.cluster.nodes)
    {{Jido.Persistence.Bedrock, repo: Bedrock.Repo}, {Jido.Persistence.Mnesia, table: table}}
  end

  defp storage(c, control), do: {child(c, control, {JournalAdapter, []}), nil}

  defp publish(c, f, agent, id, expected) do
    signal = Jido.Signal.new!(%{id: id, type: "counter.changed", source: "/provider-bedrock", data: %{}})
    assert {:ok, _} = f.api.(:publish, [f.topology.id, :events, signal])

    eventually(fn ->
      snapshot = cluster_call(c.cluster, f.worker, Jido.AgentServer, :snapshot, [agent])
      Enum.map(snapshot.agent.state.events, & &1.id) == expected
    end)
  end

  defp release(c, f) do
    {:ok, op} = f.api.(:release_host, [f.worker, [request_id: f.api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = f.api.(:await, [op.id])
    assert [] = resources(c, f)
  end

  defp recover(f) do
    assert :ok = f.api.(:reconcile, [])
    eventually(fn -> not f.api.(:status, []).recovering end)
  end

  defp resources(c, f), do: cluster_call(c.cluster, f.control, HostProvider, :resources, [f.provider])

  defp child(c, host, spec) do
    {:ok, pid} = cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, spec])
    pid
  end

  defp stop(c, host, pid) do
    assert :ok = cluster_call(c.cluster, host, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, pid])
    refute cluster_call(c.cluster, host, Process, :alive?, [pid])
  end

  defp crash(c, f) do
    name = Cluster.Instance.name(Instance, Service)
    owner = cluster_call(c.cluster, f.control, Process, :whereis, [name])
    assert is_pid(owner)
    assert true = cluster_call(c.cluster, f.control, Process, :exit, [owner, :kill])
    eventually(fn -> not cluster_call(c.cluster, f.control, Process, :alive?, [f.service]) end)
    refute cluster_call(c.cluster, f.control, Process, :alive?, [owner])
  end

  defp finish(c, f) do
    assert [] = f.api.(:claims, [])
    assert [] = resources(c, f)
    stop(c, f.control, f.service)
    guard = cluster_call(c.cluster, f.worker, Process, :whereis, [HostRuntime.name(f.jido)])
    if is_pid(guard), do: stop(c, f.worker, guard)
    for {host, core} <- f.cores, do: stop(c, host, core)
    stop(c, f.control, f.provider)

    if is_pid(f.journal),
      do: stop(c, f.control, f.journal),
      else: assert(:ok = cluster_call(c.cluster, f.control, Bedrock, :stop, []))
  end
end
