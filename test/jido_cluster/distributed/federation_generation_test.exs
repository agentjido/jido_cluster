defmodule JidoCluster.Distributed.FederationGenerationTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster.Activation
  alias Jido.Cluster.Federation.{Bridge, Limits, Mirror}
  alias JidoCluster.Test.Federation.{GenerationOwner, Subscriber}

  test "remote generations require exact owner closure and exact mirror cleanup", %{cluster: cluster} do
    [control, worker] = cluster.nodes
    jido = __MODULE__.Core
    namespace = "peer-generation/#{Jido.generate_id()}"

    cores = for host <- cluster.nodes, do: {host, start(cluster, host, {Jido, name: jido, namespace: namespace})}
    owner = start(cluster, control, {GenerationOwner, jido: jido, namespace: namespace})
    activation = cluster_call(cluster, control, GenerationOwner, :activation, [owner])
    {:ok, ref} = cluster_call(cluster, worker, Jido, :agent_ref, [jido, "subscriber"])
    {:ok, agent} = cluster_call(cluster, worker, Jido, :start_agent_ref, [jido, ref, Subscriber])
    {:ok, limits} = Limits.new([])

    opts = [
      jido: jido,
      activation: activation,
      owner: owner,
      channel: "events",
      types: ["counter.changed"],
      limits: limits,
      allowed_nodes: cluster.nodes,
      bindings: [%{ref: ref, required: true}]
    ]

    assert {:ok, first} = cluster_call(cluster, worker, Mirror, :ensure, [opts])
    assert :ok = cluster_call(cluster, worker, Mirror, :attach, [first, ref, agent])
    assert :ok = cluster_call(cluster, worker, Mirror, :connect, [first, []])
    old = cluster_call(cluster, worker, Mirror, :status, [first])
    publish(cluster, worker, first, "before")
    eventually(fn -> events(cluster, worker, agent) == ["before"] end)

    assert {:error, :owner_mismatch} =
             cluster_call(cluster, worker, Activation, :settle_resource, [activation, owner, "events", 0])

    assert {:error, :invalid_resource_request} =
             cluster_call(cluster, control, Activation, :close_resource, [activation, owner, worker, "events", 0])

    assert :ok = cluster_call(cluster, control, GenerationOwner, :close, [owner, worker, 0])
    assert {:error, :resource_closed} = cluster_call(cluster, worker, Mirror, :attach, [first, ref, agent])
    assert {:error, :resource_closed} = cluster_call(cluster, worker, Mirror, :publisher, [first])

    assert {:error, :resource_cleanup_unconfirmed} =
             cluster_call(cluster, control, GenerationOwner, :prepare, [owner, worker, 1])

    assert :ok = cluster_call(cluster, worker, Mirror, :stop_generation, [jido, activation, owner, "events", 0])
    assert :ok = cluster_call(cluster, control, GenerationOwner, :prepare, [owner, worker, 1])
    assert {:error, :resource_revision_changed} = cluster_call(cluster, worker, Mirror, :ensure, [opts])
    assert {:ok, replacement} = cluster_call(cluster, worker, Mirror, :ensure, [Keyword.put(opts, :revision, 1)])
    assert :ok = cluster_call(cluster, worker, Mirror, :attach, [replacement, ref, agent])
    assert :ok = cluster_call(cluster, worker, Mirror, :connect, [replacement, []])
    current = cluster_call(cluster, worker, Mirror, :status, [replacement])
    assert current.revision == 1
    assert current.binding_readiness == :ready
    assert hd(current.bindings).id == hd(old.bindings).id
    refute hd(current.bindings).subscriptions == hd(old.bindings).subscriptions
    assert {:ok, ^agent} = cluster_call(cluster, worker, Jido, :resolve_agent, [jido, ref])

    assert {:error, :resource_revision_changed} =
             cluster_call(cluster, worker, Mirror, :stop_generation, [jido, activation, owner, "events", 0])

    assert {:ok, ^replacement} = cluster_call(cluster, worker, Mirror, :lookup, [jido, activation, "events"])
    publish(cluster, worker, replacement, "after")
    eventually(fn -> events(cluster, worker, agent) == ["before", "after"] end)
    assert :ok = cluster_call(cluster, control, GenerationOwner, :finish, [owner])
    assert {:ok, :settled} = cluster_call(cluster, control, Activation, :inspect, [activation])

    for pid <- [first, replacement] ++ Map.values(old.components) ++ Map.values(current.components),
        do: refute(cluster_call(cluster, worker, Process, :alive?, [pid]))

    assert :ok = cluster_call(cluster, worker, Jido, :stop_agent_ref, [jido, ref])
    refute cluster_call(cluster, worker, Process, :alive?, [agent])
    stop(cluster, control, owner)
    for {host, core} <- cores, do: stop(cluster, host, core)
  end

  defp publish(cluster, worker, mirror, id) do
    {:ok, publisher} = cluster_call(cluster, worker, Mirror, :publisher, [mirror])
    signal = Jido.Signal.new!(%{id: id, type: "counter.changed", source: "/peer-generation", data: %{}})
    assert {:ok, %{local: :accepted}} = cluster_call(cluster, worker, Bridge, :publish, [publisher, signal])
  end

  defp events(cluster, worker, agent),
    do: cluster_call(cluster, worker, Jido.AgentServer, :snapshot, [agent]).agent.state.events |> Enum.map(& &1.id)

  defp start(cluster, host, child) do
    assert {:ok, pid} =
             cluster_call(cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, child])

    pid
  end

  defp stop(cluster, host, pid) do
    assert :ok = cluster_call(cluster, host, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, pid])
    refute cluster_call(cluster, host, Process, :alive?, [pid])
  end
end
