defmodule JidoCluster.Examples.SharedCleanupTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.SharedCleanup
  alias JidoCluster.Examples.Support.FederationLifecycleCase, as: F

  @tag cluster_nodes: 3, tmp_dir: true
  test "stopping one deployment preserves the other's native transport and bindings", context do
    c = F.start(context, SharedCleanup)
    target = hd(c.workers)
    first = deploy_on(c, target, "first")
    second = deploy_on(c, target, "second")
    signal = SharedCleanup.Recorder.record_signal!()
    F.delivered(c, first.id, first.agent, %{signal | id: "first"}, ["first"])
    F.delivered(c, second.id, second.agent, %{signal | id: "second"}, ["second"])
    retained = Enum.filter(F.api(c, :claims), &(&1.topology_id == second.id))
    assert length(retained) == 1
    assert Enum.all?(first.mirrors, fn a -> Enum.all?(second.mirrors, &(&1.pid != a.pid)) end)

    {:ok, stop} = F.api(c, :stop, [first.id, [request_id: F.api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = F.api(c, :await, [stop.id])
    for mirror <- first.mirrors, do: F.retired(c, mirror)
    refute cluster_call(c.cluster, target, Process, :alive?, [first.agent])
    assert F.api(c, :claims) == retained
    assert target in cluster_call(c.cluster, c.control, Node, :list, [])
    assert c.control in cluster_call(c.cluster, target, Node, :list, [])

    for mirror <- second.mirrors do
      assert F.mirror(c, second.activation, mirror.host).pid == mirror.pid

      for pid <- Map.values(mirror.components),
          do: assert(cluster_call(c.cluster, mirror.host, Process, :alive?, [pid]))
    end

    assert {:ok, %{pid: agent}} = F.api(c, :lookup, [second.ref])
    assert agent == second.agent
    F.delivered(c, second.id, agent, %{signal | id: "after-stop"}, ["second", "after-stop"])
    assert {:error, :stopped} = F.api(c, :publish, [first.id, :events, signal])
    assert {:ok, %{phase: :completed}} = F.api(c, :operation, [second.operation])
    F.cleanup(c, second.id, agent)
  end

  defp deploy_on(c, target, prefix) do
    topology =
      Enum.find_value(1..100, fn number ->
        candidate = SharedCleanup.new!(id: "#{prefix}-#{number}")

        case F.api(c, :plan, [candidate]) do
          {:ok, %{placements: %{"listener" => ^target}}} -> candidate
          _ -> nil
        end
      end)

    assert topology != nil
    {:ok, operation} = F.api(c, :deploy, [topology, [request_id: F.api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = F.api(c, :await, [operation.id])
    {:ok, ref} = F.api(c, :ref, [topology.id, :listener])
    {:ok, %{pid: agent}} = F.api(c, :lookup, [ref])
    assert node(agent) == target
    {:ok, %{activation: activation}} = F.api(c, :status, [topology.id])
    mirrors = for host <- [c.control, target], do: F.mirror(c, activation, host)
    %{id: topology.id, agent: agent, ref: ref, activation: activation, mirrors: mirrors, operation: operation.id}
  end
end
