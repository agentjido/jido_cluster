defmodule JidoCluster.RecoveryTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster
  alias JidoCluster.Test.{JournalAdapter, OperationBarrier}
  alias JidoCluster.Test.PlacementWorker, as: Worker
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling
  import JidoCluster.Test.Eventually

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster
  end

  setup do
    server = start_supervised!({JournalAdapter, []})
    table = __MODULE__
    assert {:atomic, :ok} = :mnesia.create_table(table, attributes: [:key, :value], ram_copies: [node()])
    on_exit(fn -> assert {:atomic, :ok} = :mnesia.delete_table(table) end)
    topology = RequirementScheduling.new!(id: "recovering")

    options = [
      namespace: "recovery/#{Jido.generate_id()}",
      journal: {JournalAdapter, server: server},
      agent_persistence: {Jido.Persistence.Mnesia, table: table},
      registry: %{
        "schema/v1" => {:schema, topology.definition.schema},
        "worker/v1" => {:agent, Worker},
        "node" => {:atom, :node}
      },
      pools: [workers: [hosts: [%{node: node(), capacity: 2, labels: ["compute"], available: true}]]]
    ]

    start_supervised!({Service, options})
    %{options: options, topology: topology, server: server}
  end

  test "running intent restores committed state only after prior cleanup", c do
    token = Cluster.request_id(Service)
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: token)
    {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    {:ok, ref} = Cluster.ref(Service, c.topology.id, :worker)
    {:ok, %{pid: previous}} = Cluster.lookup(Service, ref)
    {:ok, _} = Cluster.call(Service, ref, Worker.work_signal!())
    {:ok, %{activation: activation}} = Cluster.status(Service, c.topology.id)
    stop_supervised!(Service)
    refute Process.alive?(previous)
    start_supervised!({Service, c.options})
    assert %{status: :reconciliation_required} = Cluster.status(Service)
    assert :ok = Cluster.reconcile(Service)
    eventually(fn -> match?({:ok, %{agent_readiness: :ready}}, Cluster.status(Service, c.topology.id)) end)
    {:ok, %{pid: current}} = Cluster.lookup(Service, ref)
    assert current != previous
    assert %{agent: %{state: %{count: 1}}} = Jido.AgentServer.snapshot(current)
    {:ok, %{activation: replacement}} = Cluster.status(Service, c.topology.id)
    refute replacement.id == activation.id
    assert {:ok, %{id: id, phase: :completed}} = Cluster.deploy(Service, c.topology, request_id: token)
    assert id == operation.id
    assert [%{ref: ^ref, state: :active}] = Cluster.claims(Service)
    {:ok, stop} = Cluster.stop(Service, c.topology.id, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, stop.id)
    refute Process.alive?(current)
  end

  test "running recovery does not require an expired operation record", c do
    token = Cluster.request_id(Service)
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: token)
    {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    for _ <- 1..63, do: Cluster.enable_host(Service, node(), request_id: Cluster.request_id(Service))
    assert %{epoch: 1} = Cluster.request_id(Service)
    stop_supervised!(Service)
    start_supervised!({Service, c.options})
    assert :ok = Cluster.reconcile(Service)
    eventually(fn -> match?({:ok, %{agent_readiness: :ready}}, Cluster.status(Service, c.topology.id)) end)
    assert {:error, :not_found} = Cluster.operation(Service, operation.id)
    assert {:error, :expired_request} = Cluster.deploy(Service, c.topology, request_id: token)
  end

  test "a stopped deployment leaves empty attached capacity available after owner recovery", c do
    stop_supervised!(Service)
    jido = __MODULE__.AttachedCore

    core =
      start_supervised!(
        {Jido, name: jido, namespace: c.options[:namespace], persistence: c.options[:agent_persistence]}
      )

    options = c.options |> Keyword.drop([:namespace, :agent_persistence]) |> Keyword.put(:jido, jido)
    start_supervised!({Service, options})
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    {:ok, ref} = Cluster.ref(Service, c.topology.id, :worker)
    {:ok, %{pid: previous}} = Cluster.lookup(Service, ref)
    {:ok, stop} = Cluster.stop(Service, c.topology.id, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, stop.id)
    refute Process.alive?(previous)
    assert Cluster.claims(Service) == []

    host = Cluster.HostRuntime.name(jido)
    %{incarnation: incarnation} = Cluster.HostRuntime.status(host)
    stop_supervised!(Service)
    assert Process.alive?(core)
    eventually(fn -> Cluster.HostRuntime.status(host).allocations["default"].control == :reconcile end)
    start_supervised!({Service, options})
    assert :ok = Cluster.reconcile(Service)
    eventually(fn -> Cluster.status(Service).status == :ready end)

    replacement = RequirementScheduling.new!(id: "independent-after-stop")
    {:ok, next} = Cluster.deploy(Service, replacement, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, next.id)
    assert [%{host_incarnation: ^incarnation, state: :active}] = Cluster.claims(Service)
    assert {:error, :stopped} = Cluster.lookup(Service, ref)
    assert {:ok, %{phase: :completed}} = Cluster.operation(Service, stop.id)
    {:ok, stopped} = Cluster.stop(Service, replacement.id, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, stopped.id)
    assert Cluster.claims(Service) == []
    stop_supervised!(Service)
    assert Process.alive?(core)
  end

  test "a committed acceptance with a lost reply resumes its original request", c do
    token = Cluster.request_id(Service)
    :ok = JournalAdapter.mode(c.server, :commit_then_lose)
    assert {:error, {:journal_write_failed, _}} = Cluster.deploy(Service, c.topology, request_id: token)
    assert :ok = Cluster.reconcile(Service)
    eventually(fn -> match?({:ok, %{agent_readiness: :ready}}, Cluster.status(Service, c.topology.id)) end)
    assert {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: token)
    assert operation.phase == :completed
    assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
    assert [_] = Cluster.claims(Service)
  end

  test "a lost host binding reply closes the unused attempt before recovery", c do
    token = Cluster.request_id(Service)
    :ok = JournalAdapter.mode(c.server, {:hold, self()})
    deploy = Task.async(fn -> Cluster.deploy(Service, c.topology, request_id: token) end)
    assert_receive {:journal_written, caller, ref}, 5_000
    :ok = JournalAdapter.mode(c.server, :commit_then_lose)
    send(caller, {:release, ref})
    assert {:ok, operation} = Task.await(deploy)
    assert {:error, :journal_unavailable} = Cluster.await(Service, operation.id)
    eventually(fn -> Cluster.reconcile(Service) == :ok end)
    eventually(fn -> match?({:ok, %{agent_readiness: :ready}}, Cluster.status(Service, c.topology.id)) end)
    assert {:ok, %{phase: :completed, id: id}} = Cluster.deploy(Service, c.topology, request_id: token)
    assert id == operation.id
    assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
    assert [%{state: :active}] = Cluster.claims(Service)
  end

  test "a lost completion reply cleans the original Agent before replacement", c do
    barrier = OperationBarrier.attach(self(), c.topology.id)
    on_exit(fn -> :telemetry.detach(barrier) end)
    token = Cluster.request_id(Service)
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: token)
    assert_receive {:operation_observed, task, _}, 5_000
    {:ok, ref} = Cluster.ref(Service, c.topology.id, :worker)
    {:ok, previous} = Jido.resolve_agent(Service.Core, ref)
    :ok = JournalAdapter.mode(c.server, :commit_then_lose)
    send(task, :release)
    assert {:error, :journal_unavailable} = Cluster.await(Service, operation.id)
    assert :ok = Cluster.reconcile(Service)
    eventually(fn -> match?({:ok, %{agent_readiness: :ready}}, Cluster.status(Service, c.topology.id)) end)
    refute Process.alive?(previous)
    {:ok, %{pid: current}} = Cluster.lookup(Service, ref)
    assert current != previous
    assert {:ok, %{id: id, phase: :completed}} = Cluster.deploy(Service, c.topology, request_id: token)
    assert id == operation.id
    assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
  end

  test "a restarted host guard is reconciled before a replacement becomes ready", c do
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    {:ok, ref} = Cluster.ref(Service, c.topology.id, :worker)
    {:ok, %{pid: previous}} = Cluster.lookup(Service, ref)
    host = Cluster.HostRuntime.name(Service.Core)
    old = Process.whereis(host)
    %{incarnation: incarnation} = Cluster.HostRuntime.status(host)
    Process.exit(old, :kill)
    eventually(fn -> is_pid(Process.whereis(host)) and Process.whereis(host) != old end)
    eventually(fn -> match?({:ok, %{agent_readiness: :uncertain}}, Cluster.status(Service, c.topology.id)) end)
    assert :ok = Cluster.reconcile(Service)
    eventually(fn -> match?({:ok, %{agent_readiness: :ready}}, Cluster.status(Service, c.topology.id)) end)
    refute Process.alive?(previous)
    assert [%{host_incarnation: next, state: :active}] = Cluster.claims(Service)
    assert next != incarnation
    assert Cluster.HostRuntime.status(host).incarnation == next
  end

  for {stage, additional_writes} <- [{:host_adoption, 0}, {:replacement_intent, 1}] do
    test "coordinator loss after the committed #{stage} write resumes without duplicate activation", c do
      token = Cluster.request_id(Service)
      {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: token)
      {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
      {:ok, ref} = Cluster.ref(Service, c.topology.id, :worker)
      {:ok, _} = Cluster.call(Service, ref, Worker.work_signal!())
      {:ok, %{activation: original}} = Cluster.status(Service, c.topology.id)
      stop_supervised!(Service)
      start_supervised!({Service, c.options})

      :ok = JournalAdapter.mode(c.server, {:hold, self()})
      recovery = Task.async(fn -> Cluster.reconcile(Service) end)
      assert_receive {:journal_written, caller, gate}, 5_000
      :ok = JournalAdapter.mode(c.server, {:hold, self()})
      send(caller, {:release, gate})
      assert :ok = Task.await(recovery)
      assert_receive {:journal_written, caller, gate}, 5_000
      {caller, gate} = hold_later(c.server, caller, gate, unquote(additional_writes))
      assert %{active: 0} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
      {:ok, stored} = Cluster.Journal.open(c.options[:journal], token.scope)
      [deployment] = stored.record["deployments"]
      assert deployment["recovery"] == "pending"
      assert map_size(deployment["recovery_hosts"]) == 1
      check_recovery_boundary(unquote(stage), deployment, original)

      monitor = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
      owner_name = Module.concat(Service, "Service")

      eventually(fn ->
        owner = Process.whereis(owner_name)
        is_pid(owner) and owner != caller and Cluster.status(Service).status == :reconciliation_required
      end)

      send(caller, {:release, gate})
      assert :ok = Cluster.reconcile(Service)
      ready(c)
      {:ok, %{pid: agent}} = Cluster.lookup(Service, ref)
      assert %{agent: %{state: %{count: 1}}, state_version: 1} = Jido.AgentServer.snapshot(agent)
      assert [%{ref: ^ref, state: :active}] = Cluster.claims(Service)
      assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
      assert {:ok, %{id: same, phase: :completed}} = Cluster.deploy(Service, c.topology, request_id: token)
      assert same == operation.id
    end
  end

  defp hold_later(_server, caller, gate, 0), do: {caller, gate}

  defp hold_later(server, caller, gate, remaining) do
    :ok = JournalAdapter.mode(server, {:hold, self()})
    send(caller, {:release, gate})
    assert_receive {:journal_written, next, gate}, 5_000
    hold_later(server, next, gate, remaining - 1)
  end

  defp check_recovery_boundary(:host_adoption, deployment, original),
    do: assert(deployment["activation"]["id"] == original.id)

  defp check_recovery_boundary(:replacement_intent, deployment, original),
    do: refute(deployment["activation"]["id"] == original.id)

  for seed <- [7, 41, 83] do
    test "generated replay and recovery preserve the reference model for seed #{seed}", c do
      token = Cluster.request_id(Service)
      {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: token)
      {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
      {:ok, ref} = Cluster.ref(Service, c.topology.id, :worker)
      initial = %{count: 0, bindings: %{}, token: token, operation: operation.id, ref: ref}

      model =
        Enum.reduce(events(unquote(seed)), initial, fn event, model ->
          model = apply_event(event, c, model)
          check_model(c, model)
          model
        end)

      stop_token = Cluster.request_id(Service)
      {:ok, stop} = Cluster.stop(Service, c.topology.id, request_id: stop_token)
      {:ok, %{phase: :completed}} = Cluster.await(Service, stop.id)
      stop_supervised!(Service)
      start_supervised!({Service, c.options})
      assert :ok = Cluster.reconcile(Service)
      assert {:ok, %{desired: :stopped, agent_readiness: :stopped}} = Cluster.status(Service, c.topology.id)
      assert Cluster.claims(Service) == []
      assert {:ok, %{id: same}} = Cluster.stop(Service, c.topology.id, request_id: stop_token)
      assert same == stop.id
      assert Cluster.request_id(Service).generation == model.token.generation
    end
  end

  defp events(seed) do
    choices = [:work, :restart, :reconcile, :duplicate, :unknown_write]
    random = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})

    generated =
      Stream.unfold(random, fn state ->
        {index, state} = :rand.uniform_s(length(choices), state)
        {Enum.at(choices, index - 1), state}
      end)

    choices ++ Enum.take(generated, 27)
  end

  defp apply_event(:work, _c, model) do
    assert {:ok, _} = Cluster.call(Service, model.ref, Worker.work_signal!())
    %{model | count: model.count + 1}
  end

  defp apply_event(:restart, c, model) do
    stop_supervised!(Service)
    start_supervised!({Service, c.options})
    assert :ok = Cluster.reconcile(Service)
    ready(c)
    model
  end

  defp apply_event(:reconcile, c, model) do
    {:ok, %{pid: previous}} = Cluster.lookup(Service, model.ref)
    assert :ok = Cluster.reconcile(Service)
    ready(c)
    assert {:ok, %{pid: ^previous}} = Cluster.lookup(Service, model.ref)
    model
  end

  defp apply_event(:duplicate, c, model) do
    {:ok, %{pid: previous}} = Cluster.lookup(Service, model.ref)
    assert {:ok, %{id: same}} = Cluster.deploy(Service, c.topology, request_id: model.token)
    assert same == model.operation
    assert {:ok, %{pid: ^previous}} = Cluster.lookup(Service, model.ref)
    model
  end

  defp apply_event(:unknown_write, c, model) do
    token = Cluster.request_id(Service)
    :ok = JournalAdapter.mode(c.server, :commit_then_lose)
    assert {:error, {:journal_write_failed, _}} = Cluster.enable_host(Service, node(), request_id: token)
    assert :ok = Cluster.reconcile(Service)
    ready(c)
    assert {:ok, operation} = Cluster.enable_host(Service, node(), request_id: token)
    %{model | bindings: Map.put(model.bindings, token, operation.id)}
  end

  defp ready(c) do
    eventually(fn ->
      Cluster.status(Service).recovering == false and
        match?({:ok, %{agent_readiness: :ready}}, Cluster.status(Service, c.topology.id))
    end)
  end

  defp check_model(c, model) do
    assert {:ok, %{desired: :running, agent_readiness: :ready}} = Cluster.status(Service, c.topology.id)
    assert [%{ref: ref, state: :active}] = Cluster.claims(Service)
    assert ref == model.ref
    {:ok, %{pid: agent}} = Cluster.lookup(Service, ref)
    assert %{agent: %{state: %{count: count}}, state_version: count} = Jido.AgentServer.snapshot(agent)
    assert count == model.count
    assert {:ok, %{id: same, phase: :completed}} = Cluster.deploy(Service, c.topology, request_id: model.token)
    assert same == model.operation

    for {token, id} <- model.bindings do
      assert {:ok, %{id: ^id, phase: :completed}} = Cluster.enable_host(Service, node(), request_id: token)
    end

    assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(Service.Core))
  end
end
