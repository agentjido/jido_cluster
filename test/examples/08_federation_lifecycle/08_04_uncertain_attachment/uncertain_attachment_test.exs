defmodule JidoCluster.Examples.UncertainAttachmentTest do
  use JidoCluster.Test.ClusterCase, tag: :example

  alias Jido.Cluster
  alias Jido.Cluster.Examples.UncertainAttachment
  alias Jido.Cluster.Federation.Mirror
  alias Jido.Topology.Controller
  alias JidoCluster.Examples.Support.{FederationLifecycleCase, JournalReplyLoss}

  alias FederationLifecycleCase, as: F

  @tag cluster_nodes: 3, tmp_dir: true
  test "a lost target attachment reply retains uncertainty until explicit recovery", context do
    c = F.start(context, UncertainAttachment, faults: true)
    topology = UncertainAttachment.new!(id: "uncertain-attachment")
    {:ok, deployed} = F.api(c, :deploy, [topology, [request_id: F.api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = F.api(c, :await, [deployed.id])
    {:ok, ref} = F.api(c, :ref, [topology.id, :listener])
    {:ok, %{pid: original}} = F.api(c, :lookup, [ref])
    source = node(original)
    [target] = c.workers -- [source]
    {:ok, %{activation: activation}} = F.api(c, :status, [topology.id])
    old_mirrors = for host <- [c.control, source], do: F.mirror(c, activation, host)
    signal = %{UncertainAttachment.Recorder.record_signal!() | id: "before"}
    F.delivered(c, topology.id, original, signal, ["before"])

    path = ["record", "deployments", 0, "federation", "phase"]
    assert :ok = cluster_call(c.cluster, c.control, JournalReplyLoss, :lose_when, [c.faults, path, "attaching"])
    token = F.api(c, :request_id)
    {:ok, drain} = F.api(c, :drain, [source, [request_id: token]])
    assert {:error, :journal_unavailable} = F.api(c, :await, [drain.id, 10_000])
    assert %{status: :journal_unavailable} = F.api(c, :status)
    assert {:ok, %{phase: :accepted}} = F.api(c, :operation, [drain.id])
    assert length(F.api(c, :claims)) == 2
    refute cluster_call(c.cluster, source, Process, :alive?, [original])
    for mirror <- old_mirrors, do: F.retired(c, mirror)

    # Core readiness and binding completion are separate receipts.
    controller = cluster_call(c.cluster, c.control, Controller, :whereis, [c.jido, topology.id])
    assert %{status: :ready} = cluster_call(c.cluster, c.control, Controller, :status, [controller])
    ready_agent = cluster_call(c.cluster, c.control, Controller, :whereis_agent, [controller, :listener])
    assert node(ready_agent) == target
    assert F.events(c, ready_agent) == ["before"]
    assert {:error, :not_found} = cluster_call(c.cluster, target, Mirror, :lookup, [c.jido, activation, "events"])
    assert {:ok, %{binding_readiness: readiness}} = F.api(c, :status, [topology.id])
    refute readiness == :ready
    assert {:error, :journal_unavailable} = F.api(c, :publish, [topology.id, :events, signal])
    {:ok, stored} = cluster_call(c.cluster, c.control, Cluster.Journal, :open, [c.backend, {c.namespace, "default"}])
    assert [record] = stored.record["deployments"]
    assert record["federation"]["phase"] == "attaching"

    assert :ok = F.api(c, :reconcile)

    eventually(fn ->
      not F.api(c, :status).recovering and
        match?({:ok, %{binding_readiness: :ready, binding_transition: nil}}, F.api(c, :status, [topology.id]))
    end)

    {:ok, %{pid: recovered}} = F.api(c, :lookup, [ref])
    assert node(recovered) == target
    assert recovered != ready_agent
    refute cluster_call(c.cluster, target, Process, :alive?, [ready_agent])
    assert {:ok, %{id: id, phase: :completed}} = F.api(c, :drain, [source, [request_id: token]])
    assert id == drain.id
    assert [%{host: ^target, state: :active}] = F.api(c, :claims)
    F.delivered(c, topology.id, recovered, %{signal | id: "after"}, ["before", "after"])
    F.cleanup(c, topology.id, recovered)
  end
end
