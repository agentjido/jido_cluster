defmodule JidoCluster.Test.JournalService do
  @moduledoc false
  use Jido.Cluster, otp_app: :jido_cluster, namespace: "backend-service-contract"
  import ExUnit.Assertions
  import JidoCluster.Test.Eventually
  alias Jido.Cluster
  alias JidoCluster.Test.PlacementWorker, as: Worker
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  def exercise(adapter) do
    topology = RequirementScheduling.new!(id: "backend-worker")

    options = options(adapter, topology)

    {token, operation, ref, agent} =
      with_instance(options, fn ->
        token = Cluster.request_id(__MODULE__)
        assert {:ok, operation} = Cluster.deploy(__MODULE__, topology, request_id: token)
        assert {:ok, %{phase: :completed}} = Cluster.await(__MODULE__, operation.id)
        {:ok, ref} = Cluster.ref(__MODULE__, topology.id, :worker)
        {:ok, %{pid: agent}} = Cluster.lookup(__MODULE__, ref)
        assert {:ok, _} = Cluster.call(__MODULE__, ref, Worker.work_signal!())
        assert %{agent: %{state: %{count: 1}}} = Jido.AgentServer.snapshot(agent)
        {token, operation, ref, agent}
      end)

    refute Process.alive?(agent)

    {stop_token, stop} =
      with_instance(options, fn ->
        assert %{status: :reconciliation_required} = Cluster.status(__MODULE__)
        assert :ok = Cluster.reconcile(__MODULE__)
        eventually(fn -> match?({:ok, %{agent_readiness: :ready}}, Cluster.status(__MODULE__, topology.id)) end)
        {:ok, %{pid: replacement}} = Cluster.lookup(__MODULE__, ref)
        assert replacement != agent
        assert %{agent: %{state: %{count: 1}}} = Jido.AgentServer.snapshot(replacement)
        assert {:ok, %{id: same, phase: :completed}} = Cluster.deploy(__MODULE__, topology, request_id: token)
        assert same == operation.id
        stop_token = Cluster.request_id(__MODULE__)
        {:ok, stop} = Cluster.stop(__MODULE__, topology.id, request_id: stop_token)
        assert {:ok, %{phase: :completed}} = Cluster.await(__MODULE__, stop.id)
        refute Process.alive?(replacement)
        {stop_token, stop}
      end)

    with_instance(options, fn ->
      assert %{status: :ready, durability: :journal} = Cluster.status(__MODULE__)
      assert {:ok, %{desired: :stopped, agent_readiness: :stopped}} = Cluster.status(__MODULE__, topology.id)
      assert Cluster.request_id(__MODULE__).generation == token.generation
      assert {:ok, %{id: id}} = Cluster.stop(__MODULE__, topology.id, request_id: stop_token)
      assert id == stop.id
      assert Cluster.claims(__MODULE__) == []
      assert %{active: 0} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(__MODULE__.Core))
    end)

    :ok
  end

  def exercise_outage({module, opts}, backend) do
    adapter = {module, Keyword.put(opts, :timeout_in_ms, 500)}
    topology = RequirementScheduling.new!(id: "backend-outage")
    options = options(adapter, topology) |> Keyword.put(:namespace, "backend-outage-contract")

    with_instance(options, fn ->
      {:ok, deployment} = Cluster.deploy(__MODULE__, topology, request_id: Cluster.request_id(__MODULE__))
      assert {:ok, %{phase: :completed}} = Cluster.await(__MODULE__, deployment.id)
      {:ok, ref} = Cluster.ref(__MODULE__, topology.id, :worker)
      {:ok, %{pid: previous}} = Cluster.lookup(__MODULE__, ref)
      assert {:ok, _} = Cluster.call(__MODULE__, ref, Worker.work_signal!())
      claims = Cluster.claims(__MODULE__)
      token = Cluster.request_id(__MODULE__)
      assert :ok = backend.stop()

      try do
        assert {:error, {:journal_write_failed, _}} = Cluster.enable_host(__MODULE__, node(), request_id: token)
        assert %{status: :journal_unavailable} = Cluster.status(__MODULE__)
        assert Cluster.claims(__MODULE__) == claims
        assert {:error, :uncertain} = Cluster.lookup(__MODULE__, ref)
        assert Process.alive?(previous)
        assert {:error, _} = Cluster.reconcile(__MODULE__)
      after
        assert {:ok, _} = backend.restart()
      end

      assert :ok = Cluster.reconcile(__MODULE__)
      eventually(fn -> Cluster.status(__MODULE__).recovering == false end)
      assert {:ok, %{agent_readiness: :ready}} = Cluster.status(__MODULE__, topology.id)
      {:ok, %{pid: current}} = Cluster.lookup(__MODULE__, ref)
      refute Process.alive?(previous)
      assert %{agent: %{state: %{count: 1}}, state_version: 1} = Jido.AgentServer.snapshot(current)
      assert {:ok, %{phase: :completed}} = Cluster.enable_host(__MODULE__, node(), request_id: token)
      assert [%{ref: ^ref, state: :active}] = Cluster.claims(__MODULE__)
      assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(__MODULE__.Core))
    end)

    :ok
  end

  defp options(adapter, topology) do
    registry = %{
      "schema/v1" => {:schema, topology.definition.schema},
      "worker/v1" => {:agent, Worker},
      "node" => {:atom, :node}
    }

    [
      journal: adapter,
      agent_persistence: adapter,
      registry: registry,
      pools: [workers: [hosts: [%{node: node(), capacity: 1, labels: ["compute"], available: true}]]]
    ]
  end

  defp with_instance(options, run) do
    {:ok, service} = DynamicSupervisor.start_child(JidoCluster.Test.Supervisor, {__MODULE__, options})

    try do
      run.()
    after
      assert :ok = DynamicSupervisor.terminate_child(JidoCluster.Test.Supervisor, service)
    end
  end
end
