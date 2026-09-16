defmodule JidoCluster.Examples.Support.FederationCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually
  alias Jido.Cluster
  alias Jido.Cluster.Federation.{Bridge, Mirror}

  defmodule OtherCluster do
    @moduledoc false
    use Jido.Cluster, otp_app: :jido_cluster
  end

  def start(c, topology, opts \\ []) do
    [control, target, unused] = c.cluster.nodes
    service = Keyword.get(opts, :service, Module.concat(topology, "Cluster"))
    jido = Module.concat(service, Core)
    namespace = "federation-example/#{System.unique_integer([:positive])}"
    cores = for host <- c.cluster.nodes, do: {host, child(c, host, {Jido, name: jido, namespace: namespace})}
    guards = for host <- [target, unused], do: {host, child(c, host, {Cluster.HostRuntime, jido: jido})}

    hosts = [
      %{node: control, labels: ["origin"], capacity: 4, available: true},
      %{node: target, labels: ["compute", "destination"], capacity: 4, available: true},
      %{node: unused, labels: ["storage"], capacity: 4, available: true}
    ]

    instance = child(c, control, {service, jido: jido, journal: :memory, pools: [workers: [hosts: hosts]]})

    Map.merge(c, %{
      control: control,
      target: target,
      unused: unused,
      service: service,
      jido: jido,
      namespace: namespace,
      instance: instance,
      cores: cores,
      guards: guards
    })
  end

  def api(c, function, args \\ []), do: cluster_call(c.cluster, c.control, Cluster, function, [c.service | args])

  def deploy(c, topology) do
    assert {:ok, operation} = api(c, :deploy, [topology, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])

    assert {:ok, %{activation: activation, agent_readiness: :ready, binding_readiness: :ready}} =
             api(c, :status, [topology.id])

    %{id: topology.id, activation: activation, operation: operation.id}
  end

  def mirror(c, deployment, host) do
    assert {:ok, mirror} = cluster_call(c.cluster, host, Mirror, :lookup, [c.jido, deployment.activation, "events"])
    components = cluster_call(c.cluster, host, Mirror, :status, [mirror]).components
    Map.merge(components, %{mirror: mirror, host: host})
  end

  def agent(c, deployment, key) do
    assert {:ok, ref} = api(c, :ref, [deployment.id, key])
    assert {:ok, %{pid: agent}} = api(c, :lookup, [ref])
    agent
  end

  def events(c, agent),
    do: cluster_call(c.cluster, node(agent), Jido.AgentServer, :snapshot, [agent]).agent.state.events

  def settled(c, mirror) do
    eventually(fn -> cluster_call(c.cluster, mirror.host, Bridge, :status, [mirror.bridge]).in_flight == 0 end)
  end

  def stop_deployment(c, deployment) do
    assert {:ok, %{channels: [channel]}} = api(c, :federation_status, [deployment.id])
    mirrors = for host <- channel.hosts, do: mirror(c, deployment, host.host)
    assert {:ok, operation} = api(c, :stop, [deployment.id, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])

    for mirror <- mirrors,
        {role, pid} <- mirror,
        role != :host,
        do: refute(cluster_call(c.cluster, mirror.host, Process, :alive?, [pid]))
  end

  def cleanup(c) do
    assert [] = api(c, :claims)
    stop_child(c, c.control, c.instance)
    for {host, pid} <- c.guards ++ c.cores, do: stop_child(c, host, pid)

    eventually(fn ->
      cluster_call(c.cluster, c.control, Process, :whereis, [Cluster.HostRuntime.name(c.jido)]) == nil
    end)
  end

  def child(c, host, spec) do
    assert {:ok, pid} =
             cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, spec])

    pid
  end

  def stop_child(c, host, pid) do
    assert :ok = cluster_call(c.cluster, host, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, pid])
    refute cluster_call(c.cluster, host, Process, :alive?, [pid])
  end
end
