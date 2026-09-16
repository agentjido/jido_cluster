defmodule JidoCluster.Examples.Support.HostProviderScenario do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually

  alias Jido.Cluster.Examples.{
    AbruptDeathCleanup,
    AcquiredTopology,
    BorrowedAndIncompatible,
    LostAcquireReply,
    ReleaseGuard
  }

  alias Jido.Cluster.Federation.Mirror
  alias Jido.Cluster.HostProvider.{Resource, Step}
  alias Jido.Cluster.HostRuntime
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.JournalReplyLoss

  def acquired(c) do
    topology = AcquiredTopology.new!(id: "owned-subscriber")
    assert {:error, {:no_capacity, "listener"}} = H.api(c, :plan, [topology])
    H.acquire(c)

    assert {:ok, %{admission: :open, session: %{phase: :ready, resource: resource}}} =
             H.api(c, :host_status, [c.worker])

    assert [^resource] = H.provider(c, :resources)
    deployment = H.deploy(c, topology)
    signal = %{AcquiredTopology.Recorder.record_signal!() | id: "committed"}
    H.delivered(c, deployment, signal, ["committed"])
    token = H.api(c, :request_id)
    {:ok, release} = H.api(c, :release_host, [c.worker, [request_id: token]])
    assert {:ok, %{phase: :uncertain, reason: :claims_retained}} = H.api(c, :await, [release.id])
    assert {:ok, %{admission: :closed}} = H.api(c, :host_status, [c.worker])
    assert [^resource] = H.provider(c, :resources)
    refute Enum.any?(H.provider(c, :calls), &match?({:release, _}, &1))
    assert cluster_call(c.cluster, c.worker, Process, :alive?, [deployment.agent])
    H.delivered(c, deployment, %{signal | id: "retained"}, ["committed", "retained"])
    H.stop(c, deployment)
    H.reconcile(c)

    assert {:ok, %{phase: :completed, id: id}} =
             H.api(c, :release_host, [c.worker, [request_id: token]])

    assert id == release.id
    assert [] = H.provider(c, :resources)
    assert {:ok, %{admission: :closed, session: %{phase: :released}}} = H.api(c, :host_status, [c.worker])
    assert [%{"phase" => "released", "resource" => saved}] = H.record(c)["host_sessions"]
    assert saved == Resource.to_record(resource)
    H.cleanup(c)
  end

  def lost_reply(c) do
    topology = LostAcquireReply.new!(id: "recovered-subscriber")
    assert :ok = H.provider(c, :mode, [:lose_acquire_reply])
    token = H.api(c, :request_id)
    {:ok, acquire} = H.api(c, :acquire_host, [c.worker, [request_id: token]])
    assert {:ok, %{phase: :uncertain}} = H.api(c, :await, [acquire.id])
    assert [resource] = H.provider(c, :resources)

    assert {:ok, %{admission: :closed, session: %{step: step, resource: nil, attempted: true}}} =
             H.api(c, :host_status, [c.worker])

    assert step == resource.step
    assert [%{"step" => stored_step, "attempted" => true}] = H.record(c)["host_sessions"]
    assert stored_step == Step.to_record(step)
    c = H.restart_owner(c)
    assert :ok = H.provider(c, :mode, [:inspect_unavailable])
    H.reconcile(c)

    assert {:ok, %{admission: :closed, session: %{step: ^step, phase: :uncertain}}} =
             H.api(c, :host_status, [c.worker])

    assert {:error, {:no_capacity, "listener"}} = H.api(c, :plan, [topology])
    assert [^resource] = H.provider(c, :resources)
    H.reconcile(c)
    assert {:ok, %{phase: :completed, id: id}} = H.api(c, :acquire_host, [c.worker, [request_id: token]])
    assert id == acquire.id

    assert {:ok, %{admission: :open, session: %{step: ^step, resource: ^resource, phase: :ready}}} =
             H.api(c, :host_status, [c.worker])

    calls = H.provider(c, :calls)
    assert [{:acquire, ^step}] = Enum.filter(calls, &match?({:acquire, _}, &1))
    assert Enum.all?(for({:inspect, inspected} <- calls, do: inspected), &(&1 == step))
    assert [%{"resource" => saved}] = H.record(c)["host_sessions"]
    assert saved == Resource.to_record(resource)
    deployment = H.deploy(c, topology)
    signal = %{LostAcquireReply.Recorder.record_signal!() | id: "after-recovery"}
    H.delivered(c, deployment, signal, ["after-recovery"])
    H.stop(c, deployment)
    H.release(c)
    H.cleanup(c)
  end

  def borrowed(c) do
    before = H.provider(c, :calls)
    guard = cluster_call(c.cluster, c.worker, Process, :whereis, [HostRuntime.name(c.jido)])
    assert is_pid(guard)
    H.acquire(c)
    deployment = H.deploy(c, BorrowedAndIncompatible.new!(id: "borrowed"))
    signal = %{BorrowedAndIncompatible.Recorder.record_signal!() | id: "borrowed-event"}
    H.delivered(c, deployment, signal, ["borrowed-event"])
    H.stop(c, deployment)
    {:ok, operation} = H.api(c, :release_host, [c.worker, [request_id: H.api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = H.api(c, :await, [operation.id])
    assert {:ok, %{admission: :closed, session: %{phase: :retained}}} = H.api(c, :host_status, [c.worker])
    assert [c.borrowed] == H.provider(c, :resources)
    assert cluster_call(c.cluster, c.worker, Process, :alive?, [guard])
    for {host, core} <- c.cores, do: assert(cluster_call(c.cluster, host, Process, :alive?, [core]))
    calls = Enum.drop(H.provider(c, :calls), length(before))
    refute Enum.any?(calls, &(elem(&1, 0) in [:acquire, :release]))
    assert [%{"phase" => "retained", "ownership" => "borrowed"}] = H.record(c)["host_sessions"]

    # The fixture owns the resource outside this scope. Only fixture cleanup
    # removes it, after the retained-resource assertions above.
    assert :ok = H.effect(c, :release, c.borrowed)

    H.cleanup(c)
  end

  def incompatible(c) do
    topology = BorrowedAndIncompatible.new!(id: "incompatible")
    {:ok, operation} = H.api(c, :acquire_host, [c.worker, [request_id: H.api(c, :request_id)]])
    assert {:ok, %{phase: :uncertain, reason: {:incompatible, :namespace}}} = H.await_host(c, operation)
    assert {:ok, %{admission: :closed, session: %{host_incarnation: nil}}} = H.api(c, :host_status, [c.worker])
    assert {:error, {:no_capacity, "listener"}} = H.api(c, :plan, [topology])

    assert %{active: 0} =
             cluster_call(c.cluster, c.worker, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(c.jido)])

    assert [] = H.api(c, :claims)
    assert [_] = H.provider(c, :resources)
    H.release(c)
    assert {:ok, %{phase: :failed, reason: :released_before_ready}} = H.api(c, :operation, [operation.id])
    H.cleanup(c)
  end

  def release_guard(c) do
    H.acquire(c)
    deployment = H.deploy(c, ReleaseGuard.new!(id: "guarded"))
    signal = %{ReleaseGuard.Recorder.record_signal!() | id: "before-partition"}
    H.delivered(c, deployment, signal, ["before-partition"])
    [resource] = H.provider(c, :resources)
    token = H.api(c, :request_id)
    {:ok, release} = H.api(c, :release_host, [c.worker, [request_id: token]])
    assert {:ok, %{phase: :uncertain, reason: :claims_retained}} = H.api(c, :await, [release.id])
    remote = Enum.find(deployment.mirrors, &(&1.host == c.worker))

    assert %{bindings: [%{required: true, ready: true, subscription_count: 1}]} =
             cluster_call(c.cluster, c.worker, Mirror, :status, [remote.pid])

    cookie = cluster_call(c.cluster, c.control, Node, :get_cookie, [])
    on_exit(fn -> H.if_present(c, resource, fn -> reconnect(c, cookie) end) end)
    assert true = cluster_call(c.cluster, c.control, Node, :set_cookie, [c.worker, :release_control_partition])
    assert true = cluster_call(c.cluster, c.worker, Node, :set_cookie, [c.control, :release_worker_partition])
    cluster_call(c.cluster, c.control, Node, :disconnect, [c.worker])
    cluster_call(c.cluster, c.worker, Node, :disconnect, [c.control])
    eventually(fn -> cluster_call(c.cluster, c.worker, Mirror, :status, [remote.pid]).control == :uncertain end)
    {:ok, stop} = H.api(c, :stop, [deployment.id, [request_id: H.api(c, :request_id)]])
    assert {:ok, %{phase: :uncertain}} = H.api(c, :await, [stop.id])
    assert [_] = H.api(c, :claims)

    for pid <- [remote.pid | remote.components],
        do: assert(cluster_call(c.cluster, c.worker, Process, :alive?, [pid]))

    assert [^resource] = H.provider(c, :resources)
    refute Enum.any?(H.provider(c, :calls), &match?({:release, _}, &1))
    assert {:ok, %{phase: :uncertain}} = H.api(c, :operation, [release.id])
    reconnect(c, cookie)
    H.reconcile(c)
    assert {:ok, %{phase: :completed}} = H.api(c, :operation, [stop.id])
    assert {:ok, %{phase: :completed, id: id}} = H.api(c, :release_host, [c.worker, [request_id: token]])
    assert id == release.id
    assert [] = H.api(c, :claims)
    assert [] = H.provider(c, :resources)
    H.stopped(c, c.worker, [deployment.agent])

    for mirror <- deployment.mirrors, do: H.stopped(c, mirror.host, [mirror.pid | mirror.components])

    H.cleanup(c)
  end

  def stale_resource(c) do
    H.acquire(c)
    [previous] = H.provider(c, :resources)
    assert {:ok, current} = H.provider(c, :replace, [previous])
    refute current.id == previous.id
    refute current.incarnation == previous.incarnation
    H.stale_release(c, previous)
    assert [^current] = H.provider(c, :resources)
    token = H.api(c, :request_id)
    {:ok, release} = H.api(c, :release_host, [c.worker, [request_id: token]])
    assert {:ok, %{phase: :uncertain, reason: :resource_identity_changed}} = H.api(c, :await, [release.id])
    assert [^current] = H.provider(c, :resources)
    assert [{:release, ^previous}] = Enum.filter(H.provider(c, :calls), &match?({:release, _}, &1))
    assert {:ok, %{admission: :closed, session: %{resource: ^previous}}} = H.api(c, :host_status, [c.worker])

    # This replacement is owned by the fixture, not by the recorded session.
    # Remove it only after the preservation assertions, using its exact handle.
    assert :ok = effect(c, :release, current)
    H.reconcile(c)
    assert {:ok, %{phase: :completed, id: id}} = H.api(c, :release_host, [c.worker, [request_id: token]])
    assert id == release.id
    H.cleanup(c)
  end

  def abrupt_death(c) do
    [target, live, borrowed, changed] = c.workers
    for worker <- c.workers, do: H.acquire(%{c | worker: worker})
    target_resource = resource(c, target)
    live_resource = resource(c, live)
    previous = resource(c, changed)
    borrowed_resource = c.host_configs[borrowed].borrowed
    borrowed_guard = cluster_call(c.cluster, borrowed, Process, :whereis, [HostRuntime.name(c.jido)])
    borrowed_release = release(c, borrowed)
    assert {:ok, %{phase: :completed}} = H.api(c, :await, [borrowed_release.id])
    assert {:ok, replacement} = H.provider(c, :replace, [previous])
    changed_release = release(c, changed)

    assert {:ok, %{phase: :uncertain, reason: :resource_identity_changed}} =
             H.api(c, :await, [changed_release.id])

    target_deployment = deploy_on(c, target, "cleanup")
    live_deployment = deploy_on(c, live, "preserved")
    signal = AbruptDeathCleanup.Recorder.record_signal!()
    H.delivered(c, target_deployment, %{signal | id: "target-commit"}, ["target-commit"])
    H.delivered(%{c | worker: live}, live_deployment, %{signal | id: "before-crash"}, ["before-crash"])
    H.stop(c, target_deployment)
    index = Enum.find_index(H.record(c)["host_sessions"], &(&1["step"]["host"] == Atom.to_string(target)))
    path = ["record", "host_sessions", index, "phase"]
    assert :ok = cluster_call(c.cluster, c.control, JournalReplyLoss, :lose_when, [c.faults, path, "deleting"])
    target_release = release(c, target)
    assert {:error, :journal_unavailable} = H.api(c, :await, [target_release.id])
    assert Enum.any?(H.provider(c, :resources), &(&1 == target_resource))
    refute Enum.any?(H.provider(c, :calls), &match?({:release, _}, &1))
    saved = Enum.at(H.record(c)["host_sessions"], index)
    assert saved["phase"] == "deleting"
    assert saved["resource"] == Resource.to_record(target_resource)

    c = H.restart_owner(c)
    H.reconcile(c)
    assert {:ok, %{phase: :completed}} = H.api(c, :operation, [target_release.id])
    assert {:ok, %{session: %{phase: :released, resource: ^target_resource}}} = H.api(c, :host_status, [target])
    assert {:ok, %{session: %{phase: :retained, ownership: :borrowed}}} = H.api(c, :host_status, [borrowed])
    assert {:ok, %{session: %{phase: :ready, resource: ^live_resource}}} = H.api(c, :host_status, [live])

    assert {:ok, %{admission: :closed, session: %{resource: ^previous, phase: :uncertain}}} =
             H.api(c, :host_status, [changed])

    assert {:ok, %{phase: :uncertain, reason: :resource_identity_changed}} =
             H.api(c, :operation, [changed_release.id])

    assert Enum.sort(H.provider(c, :resources)) == Enum.sort([live_resource, borrowed_resource, replacement])
    assert [{:release, ^target_resource}] = Enum.filter(H.provider(c, :calls), &match?({:release, _}, &1))
    assert cluster_call(c.cluster, borrowed, Process, :alive?, [borrowed_guard])
    current = H.deployment(%{c | worker: live}, live_deployment.id)
    assert current.ref == live_deployment.ref
    refute current.agent == live_deployment.agent
    refute cluster_call(c.cluster, live, Process, :alive?, [live_deployment.agent])

    for mirror <- live_deployment.mirrors,
        pid <- [mirror.pid | mirror.components],
        do: refute(cluster_call(c.cluster, mirror.host, Process, :alive?, [pid]))

    H.delivered(%{c | worker: live}, current, %{signal | id: "after-crash"}, ["before-crash", "after-crash"])
    assert {:ok, %{desired: :stopped}} = H.api(c, :status, [target_deployment.id])
    assert {:error, :stopped} = H.api(c, :lookup, [target_deployment.ref])

    # Finish the independent workload. The fixture owns both preservation
    # controls outside the target session and removes them only now.
    H.stop(%{c | worker: live}, current)
    live_release = release(c, live)
    assert {:ok, %{phase: :completed}} = H.api(c, :await, [live_release.id])
    for resource <- [borrowed_resource, replacement], do: assert(:ok = remove(c, resource))
    H.reconcile(c)
    assert {:ok, %{phase: :completed}} = H.api(c, :operation, [changed_release.id])
    H.cleanup(c)
  end

  defp effect(c, function, resource),
    do: H.effect(c, function, resource)

  defp reconnect(c, cookie) do
    for {host, other} <- [{c.control, c.worker}, {c.worker, c.control}],
        do: assert(cluster_call(c.cluster, host, Node, :set_cookie, [other, cookie]))

    assert cluster_call(c.cluster, c.control, Node, :connect, [c.worker])
    eventually(fn -> c.worker in cluster_call(c.cluster, c.control, Node, :list, []) end)
  end

  defp resource(c, worker) do
    assert {:ok, %{session: %{resource: resource}}} = H.api(c, :host_status, [worker])
    resource
  end

  defp release(c, worker) do
    assert {:ok, operation} = H.api(c, :release_host, [worker, [request_id: H.api(c, :request_id)]])
    operation
  end

  defp deploy_on(c, worker, prefix) do
    topology =
      Enum.find_value(1..100, fn number ->
        topology = AbruptDeathCleanup.new!(id: "#{prefix}-#{number}")

        case H.api(c, :plan, [topology]) do
          {:ok, %{placements: %{"listener" => ^worker}}} -> topology
          _ -> nil
        end
      end)

    assert topology != nil
    H.deploy(%{c | worker: worker}, topology)
  end

  defp remove(c, resource),
    do: H.effect(c, :release, resource)
end
