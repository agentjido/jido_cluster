defmodule JidoCluster.Examples.Support.FederationLifecycleCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually
  alias Jido.Cluster
  alias Jido.Cluster.Federation.Mirror
  alias JidoCluster.Examples.Support.JournalReplyLoss
  alias JidoCluster.Test.Bedrock

  def start(c, topology, opts \\ []) do
    [control | workers] = c.cluster.nodes
    service = Module.concat(topology, "Cluster")
    jido = Module.concat(service, Core)
    namespace = "federation-lifecycle/#{Jido.generate_id()}"
    table = shared_table(c.cluster, c.cluster.nodes)
    persistence = {Jido.Persistence.Mnesia, table: table}

    ExUnit.Callbacks.on_exit(fn ->
      stop_node(c.cluster, control)
      File.rm_rf!(c.tmp_dir)
    end)

    assert {:ok, _} = cluster_call(c.cluster, control, Bedrock, :start, [c.tmp_dir], 40_000)
    backend = {Jido.Persistence.Bedrock, repo: Bedrock.Repo}
    faults = if opts[:faults], do: child(c, control, {JournalReplyLoss, backend})
    journal = if faults, do: {JournalReplyLoss, server: faults}, else: backend

    cores =
      for host <- c.cluster.nodes,
          do: {host, child(c, host, {Jido, name: jido, namespace: namespace, persistence: persistence})}

    guards = for host <- workers, do: {host, child(c, host, {Cluster.HostRuntime, jido: jido})}
    definition = topology.new!(id: "registry").definition

    registry = %{
      "schema/v1" => {:schema, definition.schema},
      "recorder/v1" => {:agent, Module.concat(topology, Recorder)},
      "node" => {:atom, :node}
    }

    hosts = for host <- workers, do: %{node: host, labels: ["compute"], capacity: 2, available: true}
    options = [jido: jido, journal: journal, registry: registry, pools: [workers: [hosts: hosts]]]
    instance = child(c, control, {service, options})

    Map.merge(c, %{
      control: control,
      workers: workers,
      service: service,
      jido: jido,
      namespace: namespace,
      journal: journal,
      backend: backend,
      faults: faults,
      instance: instance,
      cores: cores,
      guards: guards
    })
  end

  def api(c, function, args \\ []), do: cluster_call(c.cluster, c.control, Cluster, function, [c.service | args])

  def mirror(c, activation, host) do
    assert {:ok, pid} = cluster_call(c.cluster, host, Mirror, :lookup, [c.jido, activation, "events"])
    status = cluster_call(c.cluster, host, Mirror, :status, [pid])
    Map.merge(status, %{pid: pid, host: host})
  end

  def retired(c, mirror) do
    for pid <- [mirror.pid | Map.values(mirror.components)],
        do: refute(cluster_call(c.cluster, mirror.host, Process, :alive?, [pid]))
  end

  def events(c, agent),
    do: cluster_call(c.cluster, node(agent), Jido.AgentServer, :snapshot, [agent]).agent.state.events

  def delivered(c, id, agent, signal, expected) do
    assert {:ok, _} = api(c, :publish, [id, :events, signal])
    eventually(fn -> events(c, agent) == expected end)
  end

  def cleanup(c, id, agent) do
    {:ok, %{activation: activation}} = api(c, :status, [id])
    {:ok, %{channels: [channel]}} = api(c, :federation_status, [id])
    mirrors = for host <- channel.hosts, do: mirror(c, activation, host.host)
    {:ok, stop} = api(c, :stop, [id, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [stop.id])
    for mirror <- mirrors, do: retired(c, mirror)
    refute cluster_call(c.cluster, node(agent), Process, :alive?, [agent])
    assert [] = api(c, :claims)
    stop_child(c, c.control, c.instance)
    for {host, pid} <- c.guards ++ c.cores, do: stop_child(c, host, pid)
    if c.faults, do: stop_child(c, c.control, c.faults)
    assert :ok = cluster_call(c.cluster, c.control, Bedrock, :stop, [])
  end

  defp child(c, host, spec) do
    assert {:ok, pid} =
             cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, spec])

    pid
  end

  defp stop_child(c, host, pid) do
    assert :ok = cluster_call(c.cluster, host, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, pid])
    refute cluster_call(c.cluster, host, Process, :alive?, [pid])
  end
end
