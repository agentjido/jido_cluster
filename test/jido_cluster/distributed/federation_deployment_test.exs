defmodule JidoCluster.Distributed.FederationDeploymentTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster
  alias Jido.Cluster.Federation.{Bridge, Mirror}
  alias Jido.Signal.Bus
  alias Jido.Topology.Controller
  alias JidoCluster.Test.Federation.DeclaredTopology
  alias JidoCluster.Test.Instance

  @tag cluster_nodes: 3
  test "declarative deployment exports only to interested hosts and reports loss apart from operation history", c do
    [source, target, unused] = c.cluster.nodes
    jido = __MODULE__.Core
    namespace = "declarative-peer/#{System.unique_integer([:positive])}"
    for host <- c.cluster.nodes, do: start(c, host, {Jido, name: jido, namespace: namespace})
    start(c, target, {Cluster.HostRuntime, jido: jido})

    hosts = [
      %{node: target, labels: ["compute"], capacity: 1, available: true},
      %{node: unused, labels: ["storage"], capacity: 1, available: true}
    ]

    start(c, source, {Instance, jido: jido, journal: :memory, pools: [workers: [hosts: hosts]]})
    api = fn function, args -> cluster_call(c.cluster, source, Cluster, function, [Instance | args]) end
    topology = DeclaredTopology.new!(id: "declarative")
    assert {:ok, operation} = api.(:deploy, [topology, [request_id: api.(:request_id, [])]])
    assert {:ok, completed} = api.(:await, [operation.id])
    assert completed.phase == :completed

    assert {:ok, %{binding_readiness: :ready, federation_health: :healthy, activation: activation}} =
             api.(:status, [topology.id])

    assert {:ok, %{channels: [channel]}} = api.(:federation_status, [topology.id])
    assert channel.interested_hosts == [target]
    assert Enum.map(channel.hosts, & &1.host) == Enum.sort([source, target])
    assert {:error, :not_found} = cluster_call(c.cluster, unused, Mirror, :lookup, [jido, activation, "events"])
    {:ok, origin} = cluster_call(c.cluster, source, Mirror, :lookup, [jido, activation, "events"])
    {:ok, destination} = cluster_call(c.cluster, target, Mirror, :lookup, [jido, activation, "events"])
    origin_children = cluster_call(c.cluster, source, Mirror, :status, [origin]).components
    destination_children = cluster_call(c.cluster, target, Mirror, :status, [destination]).components
    {:ok, ref} = api.(:ref, [topology.id, :listener])
    {:ok, %{pid: agent}} = api.(:lookup, [ref])
    signal = Jido.Signal.new!(%{id: "remote-original", type: "counter.changed", source: "/test", data: %{value: 3}})

    assert {:ok, %{local: :accepted, outbound: :submitted, targets: [^target]}} =
             api.(:publish, [topology.id, :events, signal])

    eventually(fn -> cluster_call(c.cluster, target, Jido.AgentServer, :snapshot, [agent]).state_version == 1 end)

    assert cluster_call(c.cluster, target, Jido.AgentServer, :snapshot, [agent]).agent.state.events ==
             [Map.take(signal, [:id, :type, :source, :data])]

    eventually(fn -> cluster_call(c.cluster, source, Bridge, :status, [origin_children.bridge]).in_flight == 0 end)

    for {host, bus} <- [{source, origin_children.bus}, {target, destination_children.bus}] do
      assert {:ok, [record]} = cluster_call(c.cluster, host, Bus, :replay, [bus, "counter.changed"])
      assert record.signal == signal
    end

    assert %{accepted: 0} = cluster_call(c.cluster, target, Bridge, :status, [destination_children.bridge])

    assert true = cluster_call(c.cluster, source, Process, :exit, [origin_children[{:connection, target}], :kill])
    eventually(fn -> match?({:ok, %{federation_health: :degraded}}, api.(:status, [topology.id])) end)
    assert {:ok, %{agent_readiness: :ready, binding_readiness: :ready}} = api.(:status, [topology.id])
    assert {:ok, ^completed} = api.(:operation, [operation.id])
    claims = api.(:claims, [])
    assert :ok = api.(:reconcile, [])

    eventually(fn ->
      not api.(:status, []).recovering and
        match?({:ok, %{binding_intent: %{"revision" => 1}, federation_health: :healthy}}, api.(:status, [topology.id]))
    end)

    assert {:ok, %{pid: ^agent}} = api.(:lookup, [ref])
    assert api.(:claims, []) == claims
    assert {:ok, ^completed} = api.(:operation, [operation.id])
    {:ok, repaired_origin} = cluster_call(c.cluster, source, Mirror, :lookup, [jido, activation, "events"])
    {:ok, repaired_destination} = cluster_call(c.cluster, target, Mirror, :lookup, [jido, activation, "events"])
    repaired_origin_children = cluster_call(c.cluster, source, Mirror, :status, [repaired_origin]).components
    repaired_destination_children = cluster_call(c.cluster, target, Mirror, :status, [repaired_destination]).components
    assert {:ok, _} = api.(:publish, [topology.id, :events, %{signal | id: "after-repair"}])
    eventually(fn -> cluster_call(c.cluster, target, Jido.AgentServer, :snapshot, [agent]).state_version == 2 end)
    assert {:ok, stop} = api.(:stop, [topology.id, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [stop.id])

    for {host, children} <- [
          {source, [origin | Map.values(origin_children)]},
          {target, [agent, destination | Map.values(destination_children)]},
          {source, [repaired_origin | Map.values(repaired_origin_children)]},
          {target, [repaired_destination | Map.values(repaired_destination_children)]}
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

  test "participant limits reject deployment before host activation", c do
    [source, target] = c.cluster.nodes
    jido = __MODULE__.Core
    start(c, source, {Jido, name: jido, namespace: "participant-limit"})
    hosts = [%{node: target, labels: ["compute"], capacity: 1, available: true}]

    start(
      c,
      source,
      {Instance, jido: jido, journal: :memory, federation: [max_hosts: 1], pools: [workers: [hosts: hosts]]}
    )

    api = fn function, args -> cluster_call(c.cluster, source, Cluster, function, [Instance | args]) end
    topology = DeclaredTopology.new!(id: "too-many-hosts")
    assert {:error, :federation_host_limit} = api.(:plan, [topology])
    assert {:error, :federation_host_limit} = api.(:deploy, [topology, [request_id: api.(:request_id, [])]])
    assert [] = api.(:claims, [])
    assert nil == cluster_call(c.cluster, source, Controller, :whereis, [jido, topology.id])
    assert nil == cluster_call(c.cluster, target, Process, :whereis, [jido])
  end

  test "memory-mode channel drain retains the Ref and confirms replacement bindings", c do
    [source, target] = c.cluster.nodes
    jido = __MODULE__.Core
    for host <- c.cluster.nodes, do: start(c, host, {Jido, name: jido, namespace: "static-channel-drain"})
    start(c, target, {Cluster.HostRuntime, jido: jido})
    hosts = for host <- c.cluster.nodes, do: %{node: host, labels: ["compute"], capacity: 1, available: true}
    start(c, source, {Instance, jido: jido, journal: :memory, pools: [workers: [hosts: hosts]]})
    api = fn function, args -> cluster_call(c.cluster, source, Cluster, function, [Instance | args]) end
    topology = DeclaredTopology.new!(id: "static")
    {:ok, operation} = api.(:deploy, [topology, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [operation.id])
    {:ok, ref} = api.(:ref, [topology.id, :listener])
    {:ok, %{pid: agent}} = api.(:lookup, [ref])
    {:ok, drain} = api.(:drain, [node(agent), [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [drain.id, 10_000])
    assert {:ok, %{pid: replacement}} = api.(:lookup, [ref])
    refute node(replacement) == node(agent)
    assert [%{ref: ^ref, host: host, state: :active}] = api.(:claims, [])
    assert host == node(replacement)
    assert {:ok, %{binding_readiness: :ready}} = api.(:status, [topology.id])
    {:ok, stop} = api.(:stop, [topology.id, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [stop.id])
    refute cluster_call(c.cluster, node(agent), Process, :alive?, [agent])
    assert [] = api.(:claims, [])
  end
end
