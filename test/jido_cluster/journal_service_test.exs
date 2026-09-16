defmodule JidoCluster.JournalServiceTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster
  alias Jido.Cluster.Journal
  alias JidoCluster.Test.{JournalAdapter, OperationBarrier}
  alias JidoCluster.Test.PlacementWorker, as: Worker
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "journal-service"
  end

  setup do
    adapter = start_supervised!({JournalAdapter, []})
    topology = RequirementScheduling.new!(id: "durable")

    registry = %{
      "schema/v1" => {:schema, topology.definition.schema},
      "worker/v1" => {:agent, Worker},
      "node" => {:atom, :node}
    }

    options = [
      journal: {JournalAdapter, server: adapter},
      registry: registry,
      pools: [workers: [hosts: [%{node: node(), capacity: 2, labels: ["compute"], available: true}]]]
    ]

    %{adapter: adapter, options: options, topology: topology}
  end

  test "durable configuration requires an explicit trusted registry", c do
    assert {:error, {:invalid_registry, :required}} = Service.config(Keyword.delete(c.options, :registry))
    refute Process.whereis(Service.Core)
  end

  test "acceptance is stored before activation and stop intent before cleanup", c do
    start_supervised!({Service, c.options})
    token = Cluster.request_id(Service)
    :ok = JournalAdapter.mode(c.adapter, {:hold, self()})
    deploy = Task.async(fn -> Cluster.deploy(Service, c.topology, request_id: token) end)
    assert_receive {:journal_written, caller, ref}, 5_000
    assert agents() == 0
    journal = read(c)
    assert [%{"desired" => "running", "phase" => "accepted"}] = journal.record["deployments"]
    send(caller, {:release, ref})
    assert {:ok, operation} = Task.await(deploy)
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    assert agents() == 1

    token = Cluster.request_id(Service)
    :ok = JournalAdapter.mode(c.adapter, {:hold, self()})
    stop = Task.async(fn -> Cluster.stop(Service, c.topology.id, request_id: token) end)
    assert_receive {:journal_written, caller, ref}, 5_000
    assert agents() == 1
    assert [%{"desired" => "stopped", "phase" => "accepted"}] = read(c).record["deployments"]
    send(caller, {:release, ref})
    assert {:ok, operation} = Task.await(stop)
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    assert agents() == 0
    assert read(c).record["claims"] == []
  end

  test "stopped intent, request bindings and generation survive full service restart", c do
    start_supervised!({Service, c.options})
    token = Cluster.request_id(Service)
    {:ok, deploy} = Cluster.deploy(Service, c.topology, request_id: token)
    {:ok, %{phase: :completed}} = Cluster.await(Service, deploy.id)
    stop_token = Cluster.request_id(Service)
    {:ok, stop} = Cluster.stop(Service, c.topology.id, request_id: stop_token)
    {:ok, %{phase: :completed}} = Cluster.await(Service, stop.id)
    assert :ok = stop_supervised(Service)
    start_supervised!({Service, c.options})
    assert agents() == 0
    assert Cluster.request_id(Service).generation == token.generation
    assert {:ok, %{desired: :stopped, agent_readiness: :stopped}} = Cluster.status(Service, c.topology.id)
    assert {:ok, %{id: id, phase: :completed}} = Cluster.stop(Service, c.topology.id, request_id: stop_token)
    assert id == stop.id
    assert %{durability: :journal, status: :ready} = Cluster.status(Service)
    assert {:ok, %{agent_persistence: nil}} = Cluster.config(Service)
  end

  for mode <- [:commit_then_lose, :commit_then_indeterminate] do
    test "unknown acceptance #{mode} blocks work and restart discovers its original request", c do
      start_supervised!({Service, c.options})
      token = Cluster.request_id(Service)
      :ok = JournalAdapter.mode(c.adapter, unquote(mode))
      assert {:error, {:journal_write_failed, _}} = Cluster.deploy(Service, c.topology, request_id: token)
      assert agents() == 0
      assert %{status: :journal_unavailable} = Cluster.status(Service)
      assert {:error, :journal_unavailable} = Cluster.request_id(Service)
      assert [_] = Cluster.claims(Service)
      [stored] = read(c).record["operations"]
      assert :ok = stop_supervised(Service)
      start_supervised!({Service, c.options})
      assert {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: token)
      assert operation.id == stored["id"]
      assert agents() == 0
      assert %{status: :reconciliation_required} = Cluster.status(Service)
    end
  end

  test "explicit acceptance rejection permits retry with the same token", c do
    start_supervised!({Service, c.options})
    token = Cluster.request_id(Service)
    :ok = JournalAdapter.mode(c.adapter, {:return, {:error, {:rejected, :offline}}})

    assert {:error, {:journal_write_failed, {:rejected, :offline}}} =
             Cluster.deploy(Service, c.topology, request_id: token)

    assert agents() == 0
    assert Cluster.claims(Service) == []
    assert %{status: :ready} = Cluster.status(Service)
    assert {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: token)
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
  end

  test "completion cannot be reported while its journal result is unknown", c do
    start_supervised!({Service, c.options})
    barrier = OperationBarrier.attach(self(), c.topology.id)
    on_exit(fn -> :telemetry.detach(barrier) end)
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert_receive {:operation_observed, task, _}, 5_000
    :ok = JournalAdapter.mode(c.adapter, :commit_then_lose)
    send(task, :release)
    assert {:error, :journal_unavailable} = Cluster.await(Service, operation.id)
    assert %{status: :journal_unavailable} = Cluster.status(Service)
    assert [_] = Cluster.claims(Service)
    {:ok, ref} = Cluster.ref(Service, c.topology.id, :worker)
    assert {:error, :uncertain} = Cluster.lookup(Service, ref)
    assert agents() == 1
  end

  test "oversized admission fails before a write or an Agent start", c do
    start_supervised!({Service, c.options})

    topology = %{
      c.topology
      | definition: %{c.topology.definition | metadata: %{"large" => String.duplicate("x", 65_536)}}
    }

    writes = JournalAdapter.writes(c.adapter)

    assert {:error, {:aggregate_too_large, _, 65_536}} =
             Cluster.deploy(Service, topology, request_id: Cluster.request_id(Service))

    assert JournalAdapter.writes(c.adapter) == writes
    assert agents() == 0
  end

  test "an expired epoch stays expired after full service restart", c do
    start_supervised!({Service, c.options})
    first = Cluster.request_id(Service)
    {:ok, _} = Cluster.enable_host(Service, node(), request_id: first)

    for _ <- 1..63 do
      assert {:ok, _} = Cluster.enable_host(Service, node(), request_id: Cluster.request_id(Service))
    end

    next = Cluster.request_id(Service)
    assert next.epoch == 1
    assert :ok = stop_supervised(Service)
    start_supervised!({Service, c.options})
    assert Cluster.request_id(Service).epoch == 1
    assert {:error, :expired_request} = Cluster.enable_host(Service, node(), request_id: first)
    assert {:ok, _} = Cluster.enable_host(Service, node(), request_id: next)
  end

  test "a lost stop completion keeps claims charged until storage is restored", c do
    start_supervised!({Service, c.options})
    {:ok, deploy} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    {:ok, %{phase: :completed}} = Cluster.await(Service, deploy.id)
    token = Cluster.request_id(Service)
    :ok = JournalAdapter.mode(c.adapter, {:hold, self()})
    stop = Task.async(fn -> Cluster.stop(Service, c.topology.id, request_id: token) end)
    assert_receive {:journal_written, caller, ref}, 5_000
    :ok = JournalAdapter.mode(c.adapter, :commit_then_lose)
    send(caller, {:release, ref})
    {:ok, operation} = Task.await(stop)
    assert {:error, :journal_unavailable} = Cluster.await(Service, operation.id)
    assert agents() == 0
    assert [_] = Cluster.claims(Service)
    assert read(c).record["claims"] == []
    assert :ok = stop_supervised(Service)
    start_supervised!({Service, c.options})
    assert Cluster.claims(Service) == []
    assert {:ok, %{desired: :stopped, agent_readiness: :stopped}} = Cluster.status(Service, c.topology.id)
  end

  test "a conflicting scope revision blocks new activation", c do
    start_supervised!({Service, c.options})
    token = Cluster.request_id(Service)
    previous = read(c)
    assert {:ok, _} = Journal.commit(previous, previous.record)
    assert {:error, {:journal_write_failed, :conflict}} = Cluster.deploy(Service, c.topology, request_id: token)
    assert agents() == 0
    assert %{status: :journal_unavailable} = Cluster.status(Service)
  end

  test "an unfinished empty drain still requires reconciliation after restart", c do
    start_supervised!({Service, c.options})
    token = Cluster.request_id(Service)
    :ok = JournalAdapter.mode(c.adapter, :commit_then_lose)
    assert {:error, {:journal_write_failed, _}} = Cluster.drain(Service, node(), request_id: token)
    assert :ok = stop_supervised(Service)
    start_supervised!({Service, c.options})
    assert {:ok, %{phase: :accepted}} = Cluster.drain(Service, node(), request_id: token)
    assert %{status: :reconciliation_required} = Cluster.status(Service)
  end

  test "activation cleanup evidence survives a full service shutdown", c do
    start_supervised!({Service, c.options})
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    assert {:ok, %{activation: activation}} = Cluster.status(Service, c.topology.id)
    assert {:ok, {:active, owner}} = Cluster.Activation.inspect(activation)
    assert Process.alive?(owner)
    assert [%{"activation" => %{"id" => id}}] = read(c).record["deployments"]
    assert id == activation.id
    assert :ok = stop_supervised(Service)
    assert {:ok, :settled} = Cluster.Activation.inspect(activation)
    assert [%{"desired" => "running"}] = read(c).record["deployments"]
  end

  defp read(c) do
    {:ok, journal} = Journal.open({JournalAdapter, server: c.adapter}, {"journal-service", "default"})
    journal
  end

  defp agents, do: DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core)).active
end
