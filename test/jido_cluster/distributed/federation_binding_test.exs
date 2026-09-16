defmodule JidoCluster.Distributed.FederationBindingTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster
  alias Jido.Cluster.Activation
  alias Jido.Cluster.Federation.{Binding, Bridge, Limits, Mirror}
  alias Jido.Cluster.Federation.Transport.{Connected, Receiver}
  alias Jido.Signal.Bus
  alias JidoCluster.Test.Federation.SubscriberTopology
  alias JidoCluster.Test.Instance

  test "a remote import reaches a required local Agent binding and stop removes its resources", c do
    [source, target] = c.cluster.nodes
    jido = __MODULE__.Core
    namespace = "peer-binding/#{System.unique_integer([:positive])}"
    for host <- c.cluster.nodes, do: start(c, host, {Jido, name: jido, namespace: namespace})
    start(c, target, {Cluster.HostRuntime, jido: jido})
    hosts = [%{node: target, labels: ["compute"], capacity: 1, available: true}]
    start(c, source, {Instance, jido: jido, journal: :memory, pools: [workers: [hosts: hosts]]})
    api = fn function, args -> cluster_call(c.cluster, source, Cluster, function, [Instance | args]) end
    topology = SubscriberTopology.new!(id: "subscriber")
    assert {:ok, operation} = api.(:deploy, [topology, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [operation.id])
    {:ok, ref} = api.(:ref, [topology.id, :listener])
    {:ok, %{pid: agent}} = api.(:lookup, [ref])
    {:ok, %{activation: activation}} = api.(:status, [topology.id])
    {:ok, {:active, owner}} = cluster_call(c.cluster, source, Activation, :inspect, [activation])
    {:ok, limits} = Limits.new([])

    common = [
      jido: jido,
      activation: activation,
      owner: owner,
      channel: "events",
      types: ["counter.changed", "counter.barrier"],
      limits: limits,
      allowed_nodes: c.cluster.nodes
    ]

    assert {:ok, origin} = cluster_call(c.cluster, source, Mirror, :ensure, [common])

    assert {:ok, destination} =
             cluster_call(c.cluster, target, Mirror, :ensure, [
               Keyword.put(common, :bindings, [%{ref: ref, required: true}])
             ])

    assert %{binding_readiness: :pending} = cluster_call(c.cluster, target, Mirror, :status, [destination])
    assert :ok = cluster_call(c.cluster, target, Mirror, :attach, [destination, ref, agent])

    assert %{binding_readiness: :ready, bindings: [%{ready: true}]} =
             cluster_call(c.cluster, target, Mirror, :status, [destination])

    %{components: origin_children} = cluster_call(c.cluster, source, Mirror, :status, [origin])
    %{components: target_children} = cluster_call(c.cluster, target, Mirror, :status, [destination])

    # Core locality is preserved: a local Bus cannot attach to the remote PID.
    invalid = [
      jido: jido,
      bus: origin_children.bus,
      scope: {namespace, topology.id, "events"},
      types: ["counter.changed"],
      ref: ref,
      target: agent,
      required: true
    ]

    assert {:error, :invalid_binding} =
             cluster_call(c.cluster, source, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {Binding, invalid}
             ])

    receiver = cluster_call(c.cluster, target, Receiver, :endpoint, [target_children.receiver])
    destinations = [%{host: target, receiver: receiver}]

    assert {:error, :invalid_destinations} =
             cluster_call(c.cluster, source, Mirror, :connect, [origin, destinations ++ destinations])

    assert {:error, :invalid_destinations} =
             cluster_call(c.cluster, source, Mirror, :connect, [origin, [%{host: source, receiver: receiver}]])

    assert :ok = cluster_call(c.cluster, source, Mirror, :connect, [origin, destinations])
    assert :ok = cluster_call(c.cluster, source, Mirror, :connect, [origin, destinations])
    assert :ok = cluster_call(c.cluster, target, Mirror, :connect, [destination, []])
    assert {:error, :interest_changed} = cluster_call(c.cluster, source, Mirror, :connect, [origin, []])
    assert %{credits: 1} = cluster_call(c.cluster, target, Receiver, :status, [target_children.receiver])

    assert %{federation_health: :healthy, components: origin_children} =
             cluster_call(c.cluster, source, Mirror, :status, [origin])

    sender = origin_children[{:connection, target}]

    endpoint = cluster_call(c.cluster, source, Bridge, :endpoint, [origin_children.bridge])

    signal =
      Jido.Signal.new!(%{
        id: "original",
        type: "counter.changed",
        source: "/peer-publisher",
        data: %{count: 7, raw: <<255>>}
      })

    assert {:ok, %{targets: [^target]}} = cluster_call(c.cluster, source, Bridge, :publish, [endpoint, signal])
    eventually(fn -> cluster_call(c.cluster, target, Jido.AgentServer, :snapshot, [agent]).state_version == 1 end)
    snapshot = cluster_call(c.cluster, target, Jido.AgentServer, :snapshot, [agent])
    assert snapshot.agent.state.events == [Map.take(signal, [:id, :type, :source, :data])]
    assert {:ok, [record]} = cluster_call(c.cluster, target, Bus, :replay, [target_children.bus, "counter.changed"])
    assert record.signal == signal
    eventually(fn -> cluster_call(c.cluster, source, Bridge, :status, [origin_children.bridge]).in_flight == 0 end)

    assert true = cluster_call(c.cluster, source, Process, :exit, [sender, :kill])
    eventually(fn -> cluster_call(c.cluster, source, Mirror, :status, [origin]).federation_health == :degraded end)
    assert %{binding_readiness: :ready} = cluster_call(c.cluster, target, Mirror, :status, [destination])
    assert :ok = cluster_call(c.cluster, source, Mirror, :connect, [origin, destinations])
    assert %{federation_health: :degraded} = cluster_call(c.cluster, source, Mirror, :status, [origin])

    assert {:ok, %{targets: [^target]}} =
             cluster_call(c.cluster, source, Bridge, :publish, [endpoint, %{signal | id: "after-loss"}])

    eventually(fn -> cluster_call(c.cluster, source, Bridge, :status, [origin_children.bridge]).in_flight == 0 end)

    assert %{accepted: 2, appended: 1, rejected: 1} =
             cluster_call(c.cluster, source, Bridge, :status, [origin_children.bridge])

    barrier = %{signal | id: "barrier", type: "counter.barrier"}
    assert {:ok, _} = cluster_call(c.cluster, target, Jido.AgentServer, :call, [agent, barrier])

    assert [%{id: "original"}, %{id: "barrier"}] =
             cluster_call(c.cluster, target, Jido.AgentServer, :snapshot, [agent]).agent.state.events

    assert {:ok, stop} = api.(:stop, [topology.id, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [stop.id])

    for {host, children} <- [
          {source, [origin | Map.values(origin_children)]},
          {target, [agent, destination | Map.values(target_children)]}
        ],
        pid <- children,
        do: refute(cluster_call(c.cluster, host, Process, :alive?, [pid]))

    assert [] = api.(:claims, [])
  end

  defp start(c, host, child) do
    assert {:ok, pid} =
             cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, child])

    pid
  end

  test "a refused connection remains an interested target without revoking a ready binding", c do
    [source, target] = c.cluster.nodes
    jido = __MODULE__.RefusalCore
    namespace = "peer-binding-refusal/#{System.unique_integer([:positive])}"
    for host <- c.cluster.nodes, do: start(c, host, {Jido, name: jido, namespace: namespace})
    start(c, target, {Cluster.HostRuntime, jido: jido})
    hosts = [%{node: target, labels: ["compute"], capacity: 1, available: true}]
    start(c, source, {Instance, jido: jido, journal: :memory, pools: [workers: [hosts: hosts]]})
    api = fn function, args -> cluster_call(c.cluster, source, Cluster, function, [Instance | args]) end
    topology = SubscriberTopology.new!(id: "refused-connection")
    {:ok, operation} = api.(:deploy, [topology, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [operation.id])
    {:ok, ref} = api.(:ref, [topology.id, :listener])
    {:ok, %{pid: agent}} = api.(:lookup, [ref])
    {:ok, %{activation: activation}} = api.(:status, [topology.id])
    {:ok, {:active, owner}} = cluster_call(c.cluster, source, Activation, :inspect, [activation])
    {:ok, limits} = Limits.new(inbound_slots: 1)

    common = [
      jido: jido,
      activation: activation,
      owner: owner,
      channel: "events",
      types: ["counter.changed"],
      limits: limits,
      allowed_nodes: c.cluster.nodes
    ]

    {:ok, origin} = cluster_call(c.cluster, source, Mirror, :ensure, [common])

    {:ok, destination} =
      cluster_call(c.cluster, target, Mirror, :ensure, [Keyword.put(common, :bindings, [%{ref: ref, required: true}])])

    assert :ok = cluster_call(c.cluster, target, Mirror, :attach, [destination, ref, agent])
    %{components: target_children} = cluster_call(c.cluster, target, Mirror, :status, [destination])
    receiver = cluster_call(c.cluster, target, Receiver, :endpoint, [target_children.receiver])
    occupied = start(c, source, {Connected, receiver: receiver})
    destinations = [%{host: target, receiver: receiver}]
    assert :ok = cluster_call(c.cluster, source, Mirror, :connect, [origin, destinations])

    assert %{federation_health: :degraded, connections: [%{reason: :capacity}], components: children} =
             cluster_call(c.cluster, source, Mirror, :status, [origin])

    assert %{binding_readiness: :ready} = cluster_call(c.cluster, target, Mirror, :status, [destination])
    endpoint = cluster_call(c.cluster, source, Bridge, :endpoint, [children.bridge])
    signal = Jido.Signal.new!(%{type: "counter.changed", source: "/refusal", data: %{count: 1}})
    assert {:ok, %{targets: [^target]}} = cluster_call(c.cluster, source, Bridge, :publish, [endpoint, signal])
    eventually(fn -> cluster_call(c.cluster, source, Bridge, :status, [children.bridge]).in_flight == 0 end)

    assert %{accepted: 1, rejected: 1, uncertain: 0} =
             cluster_call(c.cluster, source, Bridge, :status, [children.bridge])

    assert {:ok, [_]} = cluster_call(c.cluster, source, Bus, :replay, [children.bus, "counter.changed"])
    assert {:ok, []} = cluster_call(c.cluster, target, Bus, :replay, [target_children.bus, "counter.changed"])

    assert :ok =
             cluster_call(c.cluster, source, DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               occupied
             ])

    refute cluster_call(c.cluster, source, Process, :alive?, [occupied])
    eventually(fn -> cluster_call(c.cluster, target, Receiver, :status, [target_children.receiver]).credits == 0 end)
    assert :ok = cluster_call(c.cluster, source, Mirror, :connect, [origin, destinations])
    assert %{credits: 0} = cluster_call(c.cluster, target, Receiver, :status, [target_children.receiver])
    assert %{federation_health: :degraded} = cluster_call(c.cluster, source, Mirror, :status, [origin])
    assert %{agent: %{state: %{events: []}}} = cluster_call(c.cluster, target, Jido.AgentServer, :snapshot, [agent])
    {:ok, stop} = api.(:stop, [topology.id, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [stop.id])

    for {host, pids} <- [
          {source, [origin | Map.values(children)]},
          {target, [agent, destination | Map.values(target_children)]}
        ],
        pid <- pids,
        do: refute(cluster_call(c.cluster, host, Process, :alive?, [pid]))

    assert [] = api.(:claims, [])
  end
end
