defmodule JidoCluster.Examples.SubscriptionMoveTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.SubscriptionMove
  alias Jido.Cluster.Federation.{Limits, Mirror}
  alias JidoCluster.Examples.Support.FederationLifecycleCase, as: F

  @tag cluster_nodes: 3, tmp_dir: true
  test "a drained subscriber retains its Ref and committed events", context do
    c = F.start(context, SubscriptionMove)
    topology = SubscriptionMove.new!(id: "moving-events")
    {:ok, deploy} = F.api(c, :deploy, [topology, [request_id: F.api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = F.api(c, :await, [deploy.id])
    {:ok, ref} = F.api(c, :ref, [topology.id, :listener])
    {:ok, %{pid: original}} = F.api(c, :lookup, [ref])
    source = node(original)
    [target] = c.workers -- [source]
    {:ok, %{activation: activation, binding_intent: prior}} = F.api(c, :status, [topology.id])
    old = F.mirror(c, activation, source)
    old_publisher = F.mirror(c, activation, c.control)
    {:ok, limits} = Limits.new([])

    old_options = [
      jido: c.jido,
      activation: activation,
      owner: old.owner,
      channel: "events",
      types: ["examples.federation_lifecycle.subscription_move.record"],
      limits: limits,
      allowed_nodes: [c.control, source],
      bindings: [%{ref: ref, required: true}],
      revision: old.revision
    ]

    first = %{SubscriptionMove.Recorder.record_signal!() | id: "before"}
    F.delivered(c, topology.id, original, first, ["before"])

    {:ok, drain} = F.api(c, :drain, [source, [request_id: F.api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = F.api(c, :await, [drain.id, 10_000])
    assert {:ok, ^ref} = F.api(c, :ref, [topology.id, :listener])
    {:ok, %{pid: moved}} = F.api(c, :lookup, [ref])
    assert node(moved) == target
    refute cluster_call(c.cluster, source, Process, :alive?, [original])
    F.retired(c, old)
    F.retired(c, old_publisher)
    assert F.events(c, moved) == ["before"]

    assert {:ok, %{binding_readiness: :ready, binding_transition: nil, binding_intent: current}} =
             F.api(c, :status, [topology.id])

    assert current["revision"] == prior["revision"] + 1
    assert hd(current["bindings"])["id"] == hd(prior["bindings"])["id"]
    assert hd(current["bindings"])["host"] == Atom.to_string(target)

    # The retired source generation rejects delayed attachment, even after target readiness.
    assert {:error, :resource_cleanup_unconfirmed} =
             cluster_call(c.cluster, source, Mirror, :ensure, [old_options])

    second = %{SubscriptionMove.Recorder.record_signal!() | id: "after"}
    F.delivered(c, topology.id, moved, second, ["before", "after"])
    assert [%{host: ^target, state: :active}] = F.api(c, :claims)
    assert {:ok, %{phase: :completed}} = F.api(c, :operation, [deploy.id])
    F.cleanup(c, topology.id, moved)
  end
end
