defmodule JidoCluster.HostSessionTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster
  alias Jido.Cluster.HostProvider.{Config, Step}
  alias Jido.Cluster.HostSession
  alias Jido.Cluster.Journal.HostSessions
  alias Jido.Cluster.Journal.Snapshot
  alias JidoCluster.Test.{HostProvider, JournalAdapter, JournalSnapshot}
  alias JidoCluster.Test.PlacementWorker, as: Worker
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "host-session"
  end

  setup do
    provider = start_supervised!(HostProvider)
    journal = start_supervised!(JournalAdapter)
    opts = [id: "test-authority", adapter: {HostProvider, server: provider}, ownership: :owned]
    %{provider: provider, journal: {JournalAdapter, server: journal}, provider_opts: opts}
  end

  test "session records retain attempted work and separate runtime incarnation", c do
    session = session("host-session", "default", node())
    assert :ok = HostSession.validate(session)
    {:ok, resource} = HostProvider.acquire(session.step, server: c.provider)

    variants = [
      session,
      %{session | phase: :acquiring, attempted: true},
      %{session | phase: :uncertain, attempted: true, reason: "acquire reply unavailable"},
      %{session | phase: :acquired, resource: resource, attempted: true},
      %{session | phase: :ready, resource: resource, attempted: true, host_incarnation: "runtime-1"},
      %{session | phase: :releasing, desired: :released, resource: resource, attempted: true},
      %{session | phase: :released, desired: :released, resource: resource, attempted: true},
      %{session | phase: :retained, desired: :released, ownership: :borrowed, resource: resource}
    ]

    for variant <- variants do
      assert {:ok, record} = HostSession.to_record(variant)
      json = record |> Jason.encode!() |> Jason.decode!()
      assert {:ok, ^variant} = HostSession.from_record(json)
    end

    for invalid <- [
          %{session | phase: :ready, resource: resource},
          %{session | phase: :acquiring, attempted: false},
          %{session | phase: :released, desired: :released},
          %{session | reason: self()},
          %{session | resource: %{resource | incarnation: self()}},
          %{session | resource: %{resource | step: %{resource.step | provider: "another"}}}
        ] do
      assert {:error, :invalid_host_session} = HostSession.to_record(invalid)
    end

    assert :ok = HostProvider.release(resource, server: c.provider)
  end

  test "scope snapshots retain exact session identity and close provider admission on read", c do
    f = JournalSnapshot.fixture()
    {:ok, providers} = Config.new(%{target: c.provider_opts}, f.config.hosts, c.journal)
    config = Map.put(f.config, :host_providers, providers)
    session = session(config.namespace, config.scope, :target)
    {:ok, resource} = HostProvider.acquire(session.step, server: c.provider)
    session = %{session | resource: resource, attempted: true, phase: :ready, host_incarnation: "runtime-1"}
    state = f.state |> Map.put(:config, config) |> Map.put(:host_sessions, %{target: session})
    assert {:ok, document} = Snapshot.encode(state, f.registry)
    bytes = Jason.encode!(document)
    refute bytes =~ "server"
    assert {:ok, restored} = Snapshot.decode(Jason.decode!(bytes), config, f.registry)
    assert restored.host_sessions == %{target: session}
    assert MapSet.member?(restored.ledger.provider_pending, :target)
    refute MapSet.member?(restored.ledger.provider_pending, :source)
    assert restored.ledger.claims == state.ledger.claims

    changed = put_in(config, [:host_providers, :target, :id], "another-authority")
    assert {:error, {:invalid_snapshot, :provider_inventory_changed}} = Snapshot.decode(document, changed, f.registry)
    assert {:error, {:invalid_snapshot, :provider_inventory_changed}} = Snapshot.decode(document, f.config, f.registry)

    duplicate = %{document | "host_sessions" => document["host_sessions"] ++ document["host_sessions"]}
    assert {:error, {:invalid_snapshot, :invalid_host_sessions}} = Snapshot.decode(duplicate, config, f.registry)
    assert :ok = HostProvider.release(resource, server: c.provider)
  end

  test "legacy static snapshots remain readable without inventing provider ownership" do
    f = JournalSnapshot.fixture()
    assert {:ok, document} = Snapshot.encode(f.state, f.registry)
    legacy = Map.drop(document, ["host_sessions", "host_providers"])
    assert {:ok, restored} = Snapshot.decode(legacy, f.config, f.registry)
    assert restored.host_sessions == %{}
    assert restored.ledger.provider_pending == MapSet.new()
  end

  test "host operation records cannot address a different host or unrecorded live step", c do
    f = JournalSnapshot.fixture()
    {:ok, providers} = Config.new(%{target: c.provider_opts}, f.config.hosts, c.journal)
    config = Map.put(f.config, :host_providers, providers)
    session = session(config.namespace, config.scope, :target)
    sessions = %{target: session}
    acquired = %{action: :acquire_host, host: :target, phase: :accepted}
    assert :ok = HostSessions.operations(sessions, %{session.operation => acquired}, config)
    assert :ok = HostSessions.operations(sessions, %{}, config)

    assert {:error, :invalid_host_operation} =
             HostSessions.operations(sessions, %{session.operation => %{acquired | host: :source}}, config)

    assert {:error, :invalid_host_operation} =
             HostSessions.operations(sessions, %{session.operation => %{acquired | action: :release_host}}, config)

    assert {:error, :invalid_host_operation} = HostSessions.operations(sessions, %{"unrecorded" => acquired}, config)
    assert :ok = HostSessions.operations(sessions, %{"old" => %{acquired | phase: :completed}}, config)

    assert {:error, :invalid_host_operation} =
             HostSessions.operations(sessions, %{"old" => %{acquired | phase: :completed, host: :source}}, config)
  end

  test "provider configuration rejects memory mode and unknown hosts before external calls", c do
    host = %{node: node(), labels: ["compute"], available: true, capacity: 1}
    assert {:error, :host_provider_requires_journal} = Config.new(%{node() => c.provider_opts}, [host], :memory)
    assert {:error, :invalid_host_providers} = Config.new(%{unknown: c.provider_opts}, [host], c.journal)
    assert {:error, :invalid_host_providers} = Config.new(%{node() => [id: "missing-adapter"]}, [host], c.journal)
    assert HostProvider.calls(c.provider) == []
  end

  test "provider inventory stays closed before acquisition even after enable and restart", c do
    topology = RequirementScheduling.new!(id: "provider-gate")
    host = %{node: node(), labels: ["compute"], available: true, capacity: 1}

    opts = [
      journal: c.journal,
      registry: %{
        "schema/v1" => {:schema, topology.definition.schema},
        "worker/v1" => {:agent, Worker},
        "node" => {:atom, :node}
      },
      pools: [workers: [hosts: [host]]],
      host_providers: %{node() => c.provider_opts}
    ]

    start_supervised!({Service, opts})
    assert {:error, {:no_capacity, "worker"}} = Cluster.plan(Service, topology)
    assert {:ok, %{phase: :completed}} = Cluster.enable_host(Service, node(), request_id: Cluster.request_id(Service))
    assert {:error, {:no_capacity, "worker"}} = Cluster.plan(Service, topology)
    stop_supervised!(Service)
    start_supervised!({Service, opts})
    assert {:error, {:no_capacity, "worker"}} = Cluster.plan(Service, topology)
    assert %{active: 0} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
    assert Cluster.claims(Service) == []
    assert HostProvider.calls(c.provider) == []
    stop_supervised!(Service)
  end

  defp session(namespace, scope, host) do
    {:ok, step} =
      Step.new(%{
        namespace: namespace,
        scope: scope,
        host: Atom.to_string(host),
        provider: "test-authority",
        id: "step-1"
      })

    {:ok, session} = HostSession.new(step, :owned, "operation-1")
    session
  end
end
