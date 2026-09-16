defmodule JidoCluster.Examples.BridgeRestartTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.BridgeRestart
  alias Jido.Cluster.Federation.Bridge
  alias JidoCluster.Examples.Support.FederationLifecycleCase, as: F
  alias JidoCluster.Test.Federation.RecordingTransport

  @tag cluster_nodes: 3, tmp_dir: true
  test "bridge repair reports an interrupted export and retains the subscriber", context do
    c = F.start(context, BridgeRestart)
    topology = BridgeRestart.new!(id: "bridge-restart")
    {:ok, deploy} = F.api(c, :deploy, [topology, [request_id: F.api(c, :request_id)]])
    assert {:ok, completed} = F.api(c, :await, [deploy.id])
    {:ok, ref} = F.api(c, :ref, [topology.id, :listener])
    {:ok, %{pid: agent}} = F.api(c, :lookup, [ref])
    {:ok, %{activation: activation, binding_intent: intent}} = F.api(c, :status, [topology.id])
    claims = F.api(c, :claims)
    original = F.mirror(c, activation, c.control)
    subscriber = F.mirror(c, activation, node(agent))
    first = %{BridgeRestart.Recorder.record_signal!() | id: "before"}
    F.delivered(c, topology.id, agent, first, ["before"])

    eventually(fn ->
      cluster_call(c.cluster, c.control, Bridge, :status, [original.components.bridge]).in_flight == 0
    end)

    # Hold one export at the transport boundary. The fresh export below uses
    # the real connection rebuilt from the stored channel declaration.
    {:ok, transport} =
      cluster_call(c.cluster, c.control, DynamicSupervisor, :start_child, [
        JidoCluster.Test.Supervisor,
        {RecordingTransport, []}
      ])

    :ok = cluster_call(c.cluster, c.control, RecordingTransport, :hold, [transport])
    endpoint = cluster_call(c.cluster, c.control, RecordingTransport, :endpoint, [transport])
    targets = [%{host: node(agent), transport: RecordingTransport, handle: endpoint}]
    assert :ok = cluster_call(c.cluster, c.control, Bridge, :set_targets, [original.components.bridge, targets])
    interrupted = %{first | id: "interrupted"}
    assert {:ok, %{local: :accepted, outbound: :submitted}} = F.api(c, :publish, [topology.id, :events, interrupted])
    eventually(fn -> cluster_call(c.cluster, c.control, RecordingTransport, :pending, [transport]) == 1 end)
    [export] = cluster_call(c.cluster, c.control, RecordingTransport, :callers, [transport])
    assert %{in_flight: 1} = cluster_call(c.cluster, c.control, Bridge, :status, [original.components.bridge])
    assert true = cluster_call(c.cluster, c.control, Process, :exit, [original.components.bridge, :kill])
    eventually(fn -> not cluster_call(c.cluster, c.control, Process, :alive?, [original.pid]) end)
    refute cluster_call(c.cluster, c.control, Process, :alive?, [export])
    F.retired(c, original)
    assert {:ok, %{agent_readiness: :ready, binding_readiness: readiness}} = F.api(c, :status, [topology.id])
    refute readiness == :ready

    assert :ok = F.api(c, :reconcile)

    eventually(fn ->
      not F.api(c, :status).recovering and
        match?(
          {:ok, %{binding_readiness: :ready, binding_intent: %{"revision" => 1}}},
          F.api(c, :status, [topology.id])
        )
    end)

    assert {:ok, %{pid: ^agent}} = F.api(c, :lookup, [ref])
    assert F.api(c, :claims) == claims
    assert {:ok, ^completed} = F.api(c, :operation, [deploy.id])
    {:ok, %{binding_intent: current}} = F.api(c, :status, [topology.id])
    assert hd(current["bindings"])["id"] == hd(intent["bindings"])["id"]
    F.retired(c, subscriber)
    F.delivered(c, topology.id, agent, %{first | id: "after"}, ["before", "after"])

    assert [%{signal: %{id: "interrupted"}}] =
             cluster_call(c.cluster, c.control, RecordingTransport, :exports, [transport])

    assert :ok =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               transport
             ])

    refute cluster_call(c.cluster, c.control, Process, :alive?, [transport])
    F.cleanup(c, topology.id, agent)
  end
end
