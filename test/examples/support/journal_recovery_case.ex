defmodule JidoCluster.Examples.Support.JournalRecoveryCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually
  alias Jido.Cluster
  alias Jido.Cluster.Examples.JournalRecovery.Worker
  alias JidoCluster.Examples.Support.JournalReplyLoss
  alias JidoCluster.Test.{Bedrock, MovementBarrier}

  def start(c, topology, backend \\ :bedrock, opts \\ []) do
    [control | workers] = c.cluster.nodes
    service = Module.concat(topology, "Cluster")
    jido = Module.concat(service, Core)
    namespace = "journal-example/#{System.unique_integer([:positive])}"
    table = shared_table(c.cluster, c.cluster.nodes)
    adapter = adapter(c, control, backend, table)
    persistence = {Jido.Persistence.Mnesia, table: table}

    for host <- c.cluster.nodes do
      assert {:ok, _} =
               cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Jido, name: jido, namespace: namespace, persistence: persistence}
               ])
    end

    for host <- workers do
      assert {:ok, _} =
               cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Cluster.HostRuntime, jido: jido}
               ])
    end

    {journal, faults} = journal(c, control, adapter, opts[:lost_reply])
    definition = topology.new!(id: "registry").definition
    registry = %{"schema/v1" => {:schema, definition.schema}, "worker/v1" => {:agent, Worker}, "node" => {:atom, :node}}
    hosts = for host <- workers, do: %{node: host, capacity: 2, labels: ["compute"], available: true}
    options = [jido: jido, journal: journal, registry: registry, pools: [workers: [hosts: hosts]]]

    assert {:ok, instance} =
             cluster_call(c.cluster, control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {service, options}
             ])

    Map.merge(c, %{
      control: control,
      workers: workers,
      service: service,
      jido: jido,
      namespace: namespace,
      instance: instance,
      options: options,
      adapter: adapter,
      backend: backend,
      faults: faults
    })
  end

  def api(c, function, args \\ []), do: cluster_call(c.cluster, c.control, Cluster, function, [c.service | args])

  def deploy(c, topology) do
    token = api(c, :request_id)
    {:ok, operation} = api(c, :deploy, [topology, [request_id: token]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])
    {:ok, ref} = api(c, :ref, [topology.id, :worker])
    {:ok, %{pid: agent}} = api(c, :lookup, [ref])
    %{token: token, operation: operation.id, ref: ref, agent: agent, topology: topology}
  end

  def selected_on(c, topology, prefix, host) do
    Enum.find_value(1..100, fn n ->
      instance = topology.new!(id: "#{prefix}-#{n}")

      case api(c, :plan, [instance]) do
        {:ok, %{placements: %{"worker" => ^host}}} -> instance
        _ -> nil
      end
    end) || raise "No example instance selects the required source"
  end

  def work(c, deployed, count) do
    for _ <- 1..count, do: assert({:ok, _} = api(c, :call, [deployed.ref, Worker.work_signal!()]))
  end

  def count(c, ref, expected) do
    {:ok, %{pid: agent}} = api(c, :lookup, [ref])

    assert %{agent: %{state: %{count: ^expected}}, state_version: ^expected} =
             cluster_call(c.cluster, node(agent), Jido.AgentServer, :snapshot, [agent])

    agent
  end

  def barrier(c) do
    {:ok, pid} =
      cluster_call(c.cluster, c.control, DynamicSupervisor, :start_child, [
        JidoCluster.Test.Supervisor,
        {MovementBarrier, []}
      ])

    pid
  end

  def waiting(c), do: cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :status])
  def release(c), do: cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :release])

  def crash(c) do
    owner = Cluster.Instance.name(c.service, Service)
    pid = cluster_call(c.cluster, c.control, Process, :whereis, [owner])
    assert true = cluster_call(c.cluster, c.control, Process, :exit, [pid, :kill])
    eventually(fn -> not cluster_call(c.cluster, c.control, Process, :alive?, [c.instance]) end)
    eventually(fn -> is_pid(cluster_call(c.cluster, c.control, Process, :whereis, [c.service])) end)
    %{c | instance: cluster_call(c.cluster, c.control, Process, :whereis, [c.service])}
  end

  def restart(c) do
    terminate(c, c.instance)

    {:ok, instance} =
      cluster_call(c.cluster, c.control, DynamicSupervisor, :start_child, [
        JidoCluster.Test.Supervisor,
        {c.service, c.options}
      ])

    %{c | instance: instance}
  end

  def recover(c) do
    assert :ok = api(c, :reconcile)
    eventually(fn -> api(c, :status).recovering == false end, timeout: 30_000)
  end

  def terminate(c, pid),
    do:
      assert(
        :ok =
          cluster_call(c.cluster, c.control, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, pid])
      )

  def cleanup(c) do
    terminate(c, c.instance)

    for host <- c.workers do
      assert %{active: 0} =
               cluster_call(c.cluster, host, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(c.jido)])
    end

    if c.backend == :bedrock, do: assert(:ok = cluster_call(c.cluster, c.control, Bedrock, :stop, []))
  end

  defp adapter(c, control, :bedrock, _table) do
    ExUnit.Callbacks.on_exit(fn ->
      stop_node(c.cluster, control)
      File.rm_rf!(c.tmp_dir)
    end)

    assert {:ok, _} = cluster_call(c.cluster, control, Bedrock, :start, [c.tmp_dir], 40_000)
    {Jido.Persistence.Bedrock, repo: Bedrock.Repo}
  end

  defp adapter(_c, _control, :mnesia, table), do: {Jido.Persistence.Mnesia, table: table}

  defp journal(c, control, adapter, true) do
    {:ok, server} =
      cluster_call(c.cluster, control, DynamicSupervisor, :start_child, [
        JidoCluster.Test.Supervisor,
        {JournalReplyLoss, adapter}
      ])

    {{JournalReplyLoss, server: server}, server}
  end

  defp journal(_, _, adapter, _), do: {adapter, nil}
end
