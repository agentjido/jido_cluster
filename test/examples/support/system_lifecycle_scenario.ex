defmodule JidoCluster.Examples.Support.SystemLifecycleScenario do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually
  alias Jido.Cluster
  alias JidoCluster.Examples.Support.{JournalRecoveryCase, JournalReplyLoss, LocationVisibilityBarrier}
  alias JidoCluster.Examples.Support.SystemLifecycleCase, as: S
  alias JidoCluster.Test.MovementBarrier

  def run(c) do
    topology = c.topology
    independent_topology = Module.concat(topology, Independent)
    recorder = Module.concat(topology, Recorder)
    stopped = S.deploy(c, independent_topology, "stopped", c.independent)
    stop_operation = S.stop(c, stopped)
    first = S.deploy(c, topology, "alpha", c.source)
    second = S.deploy(c, topology, "beta", c.source)
    signal = %{recorder.record_signal!() | id: "baseline"}
    for d <- [first, second], do: S.delivered(c, d.id, d.agent, signal, ["baseline"])

    visibility = S.child(c, c.target, {LocationVisibilityBarrier, jido: c.jido, id: first.ref.id})
    barrier = S.child(c, c.control, {MovementBarrier, []})
    token = S.api(c, :request_id)
    {:ok, drain} = S.api(c, :drain, [c.source, [request_id: token]])
    eventually(fn -> visibility(c, visibility).arrivals == 1 end)
    %{agents: [target_agent]} = visibility(c, visibility)
    assert cluster_call(c.cluster, c.target, Process, :alive?, [target_agent])
    assert {:error, :not_found} = cluster_call(c.cluster, c.target, Jido, :resolve_agent, [c.jido, first.ref])
    assert {:error, :pending} = S.api(c, :lookup, [first.ref])
    assert {:error, :busy} = S.api(c, :reconcile)
    assert visibility(c, visibility).arrivals == 1

    assert {:ok, %{activation: activation, binding_intent: %{"phase" => "planned"}}} =
             S.api(c, :status, [first.id])

    assert {:error, :not_found} =
             cluster_call(c.cluster, c.target, Cluster.Federation.Mirror, :lookup, [c.jido, activation, "events"])

    assert :ok = cluster_call(c.cluster, c.target, LocationVisibilityBarrier, :release, [visibility])

    eventually(fn -> waiting(c) != [] end)
    assert :ok = cluster_call(c.cluster, c.control, JournalReplyLoss, :hold_next, [c.faults])
    assert :ok = cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :release])
    eventually(fn -> cluster_call(c.cluster, c.control, JournalReplyLoss, :waiting, [c.faults]) end)
    {:ok, journal} = cluster_call(c.cluster, c.control, Cluster.Journal, :open, [c.backend, {c.namespace, "default"}])
    partial = Enum.find(journal.record["operations"], &(&1["id"] == drain.id))
    assert Enum.count(partial["steps"], &(&1["phase"] == "completed")) == 1
    assert length(journal.record["claims"]) == 3
    refute cluster_call(c.cluster, c.source, Process, :alive?, [first.agent])
    assert cluster_call(c.cluster, c.source, Process, :alive?, [second.agent])
    assert S.events(c, target_agent) == ["baseline"]

    c = JournalRecoveryCase.crash(c)
    assert :ok = cluster_call(c.cluster, c.control, JournalReplyLoss, :release, [c.faults])
    S.stop_child(c, c.control, barrier)
    S.stop_child(c, c.target, visibility)
    eventually(fn -> not cluster_call(c.cluster, c.source, Process, :alive?, [second.agent]) end)
    eventually(fn -> not cluster_call(c.cluster, c.target, Process, :alive?, [target_agent]) end)
    assert cluster_call(c.cluster, c.control, Process, :alive?, [c.core]) == (c.mode == :attached)
    assert %{status: :reconciliation_required} = S.api(c, :status)
    S.recover(c)
    S.provider_checkpoint(c)
    assert {:ok, %{id: id, phase: :completed}} = S.api(c, :drain, [c.source, [request_id: token]])
    assert id == drain.id
    assert {:ok, %{phase: :completed}} = S.api(c, :operation, [stop_operation])
    assert {:error, :stopped} = S.api(c, :lookup, [stopped.ref])
    prior_agents = for d <- [first, second], do: assert_ready(c, d, c.target, ["baseline"])

    assert {:ok, %{phase: :completed}} = S.api(c, :enable_host, [c.source, [request_id: S.api(c, :request_id)]])
    second_token = S.api(c, :request_id)
    assert :ok = cluster_call(c.cluster, c.control, JournalReplyLoss, :hold_next, [c.faults])

    assert {:ok, _} =
             cluster_call(c.cluster, c.control, JournalReplyLoss, :start_drain, [c.service, c.target, second_token])

    eventually(fn -> cluster_call(c.cluster, c.control, JournalReplyLoss, :waiting, [c.faults]) end)
    cookie = cluster_call(c.cluster, c.control, Node, :get_cookie, [])
    on_exit(fn -> S.reconnect_cleanup(c, c.target, cookie) end)
    S.disconnect(c, c.target)
    assert :ok = cluster_call(c.cluster, c.control, JournalReplyLoss, :release, [c.faults])
    {:ok, uncertain} = S.api(c, :drain, [c.target, [request_id: second_token]])
    assert {:ok, %{phase: :uncertain}} = S.api(c, :await, [uncertain.id, 20_000])
    claims = S.api(c, :claims)
    assert length(claims) == 4
    assert Enum.all?(claims, &(&1.host in [c.source, c.target]))

    # Erlang global can close additional links while it resolves a split.
    # Restore only the non-isolated group before testing independent capacity.
    S.connect_independent_group(c, c.target)
    S.provider_checkpoint(c)

    independent = S.deploy(c, independent_topology, "independent", c.independent)
    S.delivered(c, independent.id, independent.agent, %{signal | id: "independent"}, ["independent"])
    assert Enum.filter(S.api(c, :claims), &(&1.topology_id != independent.id)) == claims
    assert {:ok, %{phase: :uncertain}} = S.api(c, :operation, [uncertain.id])

    assert %{active: 0} =
             cluster_call(c.cluster, c.source, DynamicSupervisor, :count_children, [
               Jido.agent_supervisor_name(c.jido)
             ])

    S.reconnect(c, c.target, cookie)
    S.recover(c)
    S.provider_checkpoint(c)
    assert {:ok, %{id: id, phase: :completed}} = S.api(c, :drain, [c.target, [request_id: second_token]])
    assert id == uncertain.id
    for pid <- prior_agents, do: refute(cluster_call(c.cluster, c.target, Process, :alive?, [pid]))

    for d <- [first, second] do
      agent = assert_ready(c, d, c.source, ["baseline"])
      S.delivered(c, d.id, agent, %{signal | id: "fresh"}, ["baseline", "fresh"])
    end

    agent = assert_ready(c, independent, c.independent, ["independent"])
    S.delivered(c, independent.id, agent, %{signal | id: "fresh-independent"}, ["independent", "fresh-independent"])
    assert {:error, :stopped} = S.api(c, :lookup, [stopped.ref])
    for d <- [first, second, independent], do: S.stop(c, d)
    S.finish(c)
  end

  defp visibility(c, barrier), do: cluster_call(c.cluster, c.target, LocationVisibilityBarrier, :status, [barrier])
  defp waiting(c), do: cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :status])

  defp assert_ready(c, d, host, expected) do
    assert {:ok, %{binding_readiness: :ready, binding_transition: nil, agent_readiness: :ready}} =
             S.api(c, :status, [d.id])

    {:ok, %{pid: agent}} = S.api(c, :lookup, [d.ref])
    assert node(agent) == host
    assert S.events(c, agent) == expected
    agent
  end
end
