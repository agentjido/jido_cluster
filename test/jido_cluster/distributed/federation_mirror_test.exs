defmodule JidoCluster.Distributed.FederationMirrorTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster
  alias Jido.Cluster.Activation
  alias Jido.Cluster.Deployment.Owner
  alias Jido.Cluster.Federation.{Limits, Mirror}
  alias JidoCluster.Test.Instance
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  setup %{cluster: cluster} do
    [control, worker] = cluster.nodes
    jido = __MODULE__.Core
    namespace = "peer-mirror/#{System.unique_integer([:positive])}"

    for host <- cluster.nodes do
      assert {:ok, _} = start(cluster, host, {Jido, name: jido, namespace: namespace})
    end

    assert {:ok, _} = start(cluster, worker, {Cluster.HostRuntime, jido: jido})
    hosts = [%{node: worker, labels: ["compute"], capacity: 1, available: true}]
    topology = RequirementScheduling.new!(id: "mirror-owner")
    table = __MODULE__.Journal

    assert {:atomic, :ok} =
             cluster_call(cluster, control, :mnesia, :create_table, [
               table,
               [attributes: [:key, :value], ram_copies: [control]]
             ])

    registry = %{
      "schema/v1" => {:schema, topology.definition.schema},
      "worker/v1" => {:agent, JidoCluster.Test.PlacementWorker},
      "node" => {:atom, :node}
    }

    assert {:ok, _} =
             start(
               cluster,
               control,
               {Instance,
                jido: jido,
                journal: {Jido.Persistence.Mnesia, table: table},
                registry: registry,
                pools: [workers: [hosts: hosts]]}
             )

    api = fn function, args -> cluster_call(cluster, control, Cluster, function, [Instance | args]) end
    {:ok, operation} = api.(:deploy, [topology, [request_id: api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = api.(:await, [operation.id])
    {:ok, %{activation: activation}} = api.(:status, [topology.id])
    {:ok, {:active, owner}} = cluster_call(cluster, control, Activation, :inspect, [activation])
    {:ok, limits} = Limits.new([])

    opts = [
      jido: jido,
      activation: activation,
      owner: owner,
      channel: "events",
      types: ["counter.changed"],
      limits: limits,
      allowed_nodes: cluster.nodes
    ]

    %{control: control, worker: worker, jido: jido, activation: activation, owner: owner, api: api, opts: opts}
  end

  test "deployment cleanup finds local and remote mirrors through activation records", c do
    mirrors =
      for host <- c.cluster.nodes do
        assert {:ok, _} = cluster_call(c.cluster, host, Mirror, :ensure, [c.opts])
        assert {:ok, mirror} = cluster_call(c.cluster, host, Mirror, :lookup, [c.jido, c.activation, "events"])
        %{components: components} = cluster_call(c.cluster, host, Mirror, :status, [mirror])
        {host, [mirror | Map.values(components)]}
      end

    assert {:ok, keys} = cluster_call(c.cluster, c.control, Activation, :resources, [c.activation, c.owner])
    assert keys == Enum.sort(for host <- c.cluster.nodes, do: {host, "events"})
    stop_deployment(c)

    for {host, pids} <- mirrors, pid <- pids do
      refute cluster_call(c.cluster, host, Process, :alive?, [pid])
    end

    assert {:ok, :settled} = cluster_call(c.cluster, c.control, Activation, :inspect, [c.activation])
    assert [] = c.api.(:claims, [])
  end

  test "a live owner partition retains the remote mirror until exact cleanup after reconnect", c do
    assert {:ok, mirror} = cluster_call(c.cluster, c.worker, Mirror, :ensure, [c.opts])
    %{components: components} = cluster_call(c.cluster, c.worker, Mirror, :status, [mirror])
    cookie = cluster_call(c.cluster, c.control, Node, :get_cookie, [])
    on_exit(fn -> reconnect(c, cookie) end)
    assert true = cluster_call(c.cluster, c.control, Node, :set_cookie, [c.worker, :mirror_control_partition])
    assert true = cluster_call(c.cluster, c.worker, Node, :set_cookie, [c.control, :mirror_worker_partition])
    cluster_call(c.cluster, c.control, Node, :disconnect, [c.worker])
    cluster_call(c.cluster, c.worker, Node, :disconnect, [c.control])
    eventually(fn -> cluster_call(c.cluster, c.worker, Mirror, :status, [mirror]).control == :uncertain end)

    assert {:error, {:cleanup_hosts_unreachable, [worker]}} =
             cluster_call(c.cluster, c.control, Owner, :stop, [c.owner])

    assert worker == c.worker
    assert [_] = c.api.(:claims, [])
    for pid <- [mirror | Map.values(components)], do: assert(cluster_call(c.cluster, c.worker, Process, :alive?, [pid]))
    assert {:ok, {:active, owner}} = cluster_call(c.cluster, c.control, Activation, :inspect, [c.activation])
    assert owner == c.owner

    reconnect(c, cookie)
    assert {:ok, operation} = c.api.(:stop, ["mirror-owner", [request_id: c.api.(:request_id, [])]])
    assert {:ok, %{phase: :uncertain, reason: :reconciliation_required}} = c.api.(:await, [operation.id, 10_000])
    assert :ok = c.api.(:reconcile, [])
    eventually(fn -> match?({:ok, %{phase: :completed}}, c.api.(:operation, [operation.id])) end)
    for pid <- [mirror | Map.values(components)], do: refute(cluster_call(c.cluster, c.worker, Process, :alive?, [pid]))
    assert {:ok, :settled} = cluster_call(c.cluster, c.control, Activation, :inspect, [c.activation])
    assert [] = c.api.(:claims, [])
  end

  defp stop_deployment(c) do
    assert {:ok, operation} = c.api.(:stop, ["mirror-owner", [request_id: c.api.(:request_id, [])]])
    assert {:ok, %{phase: :completed}} = c.api.(:await, [operation.id, 10_000])
  end

  defp start(cluster, host, child),
    do: cluster_call(cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, child])

  defp reconnect(c, cookie) do
    for {host, other} <- [{c.control, c.worker}, {c.worker, c.control}] do
      assert true = cluster_call(c.cluster, host, Node, :set_cookie, [other, cookie])
    end

    assert true = cluster_call(c.cluster, c.control, Node, :connect, [c.worker])
    eventually(fn -> c.worker in cluster_call(c.cluster, c.control, Node, :list, []) end)
  end
end
