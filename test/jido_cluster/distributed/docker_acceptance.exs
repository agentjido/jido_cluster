# This explicit acceptance file is selected by `mix test.docker`. It is outside
# the default *_test.exs pattern and has only the :peer tag.
defmodule JidoCluster.Distributed.DockerAcceptanceTest do
  # Keep real infrastructure effects behind explicit invocation, also on Elixir 1.18.
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster
  alias Jido.Cluster.HostProvider.Docker
  alias Jido.Cluster.HostProvider.Resource
  alias Jido.Cluster.HostProvider.Step
  alias Jido.Cluster.HostRuntime
  alias JidoCluster.Test.{Bedrock, DockerExec, DockerReplyLoss, Instance}
  alias JidoCluster.Test.DockerEngine, as: D
  alias JidoCluster.Test.DockerHost.{Recorder, Runtime, Topology}
  @moduletag cluster_nodes: 1, timeout: 90_000

  setup_all do
    %{docker_options: D.preflight!()}
  end

  test "prepared Linux runtime connects, commits work, retains borrowed access, and is deleted", c do
    c = D.start(c, c.docker_options)
    resource = D.acquire(c)
    D.ready(c)
    assert {:ok, duplicate} = Docker.acquire(c.step, c.options)
    assert duplicate.id == resource.id
    assert duplicate.incarnation == resource.incarnation
    assert {:ok, [found]} = Docker.discover({c.namespace, "default"}, 4, c.options)
    assert found.id == resource.id
    assert {:ok, ref} = D.remote(c, Jido, :agent_ref, [Runtime.core(), "recorder"])
    assert {:ok, agent} = D.remote(c, Jido, :start_agent_ref, [Runtime.core(), ref, Recorder])
    signal = Jido.Signal.new!(%{id: "docker-commit", type: "docker.record", source: "/docker-acceptance", data: %{}})
    assert {:ok, _} = D.remote(c, Jido, :call, [Runtime.core(), ref, signal])
    assert %{agent: %{state: %{events: ["docker-commit"]}}} = D.remote(c, Jido.AgentServer, :snapshot, [agent])
    assert :ok = D.remote(c, Jido, :stop_agent_ref, [Runtime.core(), ref])
    refute D.remote(c, Process, :alive?, [agent])
    assert {:ok, restored} = D.remote(c, Jido, :start_agent_ref, [Runtime.core(), ref, Recorder])
    assert restored != agent
    assert %{agent: %{state: %{events: ["docker-commit"]}}} = D.remote(c, Jido.AgentServer, :snapshot, [restored])
    assert :ok = D.remote(c, Jido, :stop_agent_ref, [Runtime.core(), ref])
    refute D.remote(c, Process, :alive?, [restored])

    borrowed = c.options |> Keyword.delete(:container) |> Keyword.put(:borrowed_id, resource.id)
    assert {:ok, observed} = Docker.inspect(c.step, borrowed)
    assert observed.id == resource.id
    assert {:error, {:rejected, :borrowed_resource}} = Docker.acquire(c.step, borrowed)
    assert {:error, {:rejected, :docker_release_refused}} = Docker.release(observed, borrowed)
    assert {:ok, %{state: :running}} = Docker.inspect(c.step, c.options)
    stale = %{resource | incarnation: "previous-incarnation"}
    assert {:error, {:rejected, :stale_resource}} = Docker.release(stale, c.options)
    assert {:ok, %{state: :running}} = Docker.inspect(c.step, c.options)
    D.remove(c, resource)
  end

  test "a running incompatible worker is observable and exact owned cleanup deletes it", c do
    c = D.start(c, c.docker_options, ["JIDO_CLUSTER_NAMESPACE=wrong-docker-namespace"])
    resource = D.acquire(c)
    guard = HostRuntime.name(Runtime.core())

    eventually(
      fn ->
        D.remote(c, HostRuntime, :probe, [guard, [namespace: c.namespace]]) == {:error, {:incompatible, :namespace}}
      end,
      timeout: 15_000
    )

    assert %{active: 0} = D.remote(c, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(Runtime.core())])
    D.remove(c, resource)
  end

  test "Engine exec inspects a worker while its normal BEAM connection is closed", c do
    c = D.start(c, c.docker_options)
    resource = D.acquire(c)
    D.ready(c)
    cookie = cluster_call(c.cluster, c.control, Node, :get_cookie, [])
    blocked = :docker_acceptance_blocked_cookie
    assert {:ok, true} = DockerExec.call(resource, c.options, Node, :set_cookie, [c.control, blocked])
    assert true = cluster_call(c.cluster, c.control, Node, :set_cookie, [c.worker, blocked])
    assert {:ok, true} = DockerExec.call(resource, c.options, Node, :disconnect, [c.control])
    eventually(fn -> c.worker not in cluster_call(c.cluster, c.control, Node, :list, []) end)
    assert {:ok, []} = DockerExec.call(resource, c.options, Node, :list, [])

    assert {:ok, {:ok, info}} =
             DockerExec.call(resource, c.options, HostRuntime, :probe, [
               HostRuntime.name(Runtime.core()),
               [namespace: c.namespace, provider_step: Step.to_record(c.step)]
             ])

    assert info.node == c.worker
    assert {:ok, []} = DockerExec.call(resource, c.options, Node, :list, [])
    assert c.worker not in cluster_call(c.cluster, c.control, Node, :list, [])
    assert true = cluster_call(c.cluster, c.control, Node, :set_cookie, [c.worker, cookie])
    assert {:ok, true} = DockerExec.call(resource, c.options, Node, :set_cookie, [c.control, cookie])
    assert {:ok, true} = DockerExec.call(resource, c.options, Node, :connect, [c.control])
    D.ready(c)
    D.remove(c, resource)
  end

  test "failed bootstrap leaves one inspectable resource for exact cleanup", c do
    c = D.start(c, c.docker_options, ["JIDO_CLUSTER_NAMESPACE="])
    result = Docker.acquire(c.step, c.options)
    assert match?({:ok, %Resource{}}, result) or match?({:error, {:indeterminate, _}}, result)

    eventually(
      fn ->
        match?({:ok, %{state: :stopped}}, Docker.inspect(c.step, c.options))
      end,
      timeout: 15_000
    )

    assert {:ok, resource} = Docker.inspect(c.step, c.options)
    assert {:ok, [found]} = Docker.discover({c.namespace, "default"}, 4, c.options)
    assert found.id == resource.id
    assert found.incarnation == resource.incarnation

    assert {:error, :docker_worker_unavailable} =
             D.remote(c, HostRuntime, :probe, [HostRuntime.name(Runtime.core()), []])

    D.remove(c, resource)
  end

  @tag tmp_dir: true
  test "Bedrock and owner restart adopt a Docker resource after its acquisition reply is withheld", c do
    [control] = c.cluster.nodes

    on_exit(fn ->
      stop_node(c.cluster, control)
      File.rm_rf!(c.tmp_dir)
    end)

    assert {:ok, _} = cluster_call(c.cluster, control, Bedrock, :start, [c.tmp_dir], 40_000)
    c = D.start(c, c.docker_options, [], false)
    faults = child(c, {DockerReplyLoss, []})

    # The adapter records the exact step before its real Docker effect. This
    # independent record lets fixture cleanup address a lost service response.
    on_exit(fn ->
      steps = cluster_call(c.cluster, control, DockerReplyLoss, :steps, [faults])
      for step <- steps, do: D.cleanup(step, c.options)
      stop_child(c, faults)
    end)

    topology = Topology.new!(id: "docker-recovery")
    journal = {Jido.Persistence.Bedrock, repo: Bedrock.Repo}

    options = [
      jido: Runtime.core(),
      journal: journal,
      registry: %{
        "schema/v1" => {:schema, topology.definition.schema},
        "recorder/v1" => {:agent, Recorder},
        "node" => {:atom, :node}
      },
      pools: [workers: [hosts: [%{node: c.worker, labels: ["compute"], capacity: 1, available: true}]]],
      host_providers: %{
        c.worker => [id: "docker", adapter: {DockerReplyLoss, server: faults, docker: c.options}, ownership: :owned]
      }
    ]

    instance = child(c, Supervisor.child_spec({Instance, options}, restart: :temporary))
    token = api(c, :request_id)
    {:ok, acquire} = api(c, :acquire_host, [c.worker, [request_id: token]])
    assert {:ok, %{phase: :uncertain, reason: {:indeterminate, :withheld_acquire_reply}}} = api(c, :await, [acquire.id])
    assert {:ok, %{admission: :closed, session: %{step: step, resource: nil}}} = api(c, :host_status, [c.worker])
    c = %{c | step: step}
    D.ready(c)
    assert {:ok, [resource]} = Docker.discover({c.namespace, "default"}, 4, c.options)
    owner = cluster_call(c.cluster, control, Process, :whereis, [Cluster.Instance.name(Instance, Service)])
    assert is_pid(owner)
    assert true = cluster_call(c.cluster, control, Process, :exit, [owner, :kill])
    eventually(fn -> not cluster_call(c.cluster, control, Process, :alive?, [instance]) end)
    refute cluster_call(c.cluster, control, Process, :alive?, [owner])
    assert {:ok, _} = cluster_call(c.cluster, control, Bedrock, :restart, [], 40_000)
    instance = child(c, Supervisor.child_spec({Instance, options}, restart: :temporary))
    assert :ok = api(c, :reconcile)
    eventually(fn -> not api(c, :status).recovering end, timeout: 20_000)
    assert {:ok, %{phase: :completed, id: id}} = api(c, :acquire_host, [c.worker, [request_id: token]])
    assert id == acquire.id
    assert {:ok, [^resource]} = Docker.discover({c.namespace, "default"}, 4, c.options)
    calls = cluster_call(c.cluster, control, DockerReplyLoss, :calls, [faults])
    assert [{:acquire, ^step}] = Enum.filter(calls, &match?({:acquire, _}, &1))
    {:ok, deploy} = api(c, :deploy, [topology, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [deploy.id])
    {:ok, ref} = api(c, :ref, [topology.id, :listener])
    {:ok, %{pid: agent}} = api(c, :lookup, [ref])
    signal = Jido.Signal.new!(%{id: "after-adoption", type: "docker.record", source: "/docker-recovery", data: %{}})
    assert {:ok, _} = api(c, :publish, [topology.id, :events, signal])

    eventually(fn ->
      match?(%{agent: %{state: %{events: ["after-adoption"]}}}, D.remote(c, Jido.AgentServer, :snapshot, [agent]))
    end)

    {:ok, stop} = api(c, :stop, [topology.id, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [stop.id])
    refute D.remote(c, Process, :alive?, [agent])
    assert [] = api(c, :claims)
    {:ok, release} = api(c, :release_host, [c.worker, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [release.id])
    assert {:ok, :absent} = Docker.inspect(step, c.options)
    {:ok, saved} = cluster_call(c.cluster, control, Cluster.Journal, :open, [journal, {c.namespace, "default"}])
    assert [%{"phase" => "released", "resource" => record}] = saved.record["host_sessions"]
    assert record == Resource.to_record(resource)
    stop_child(c, instance)
    D.finish(c)
    assert :ok = cluster_call(c.cluster, control, Bedrock, :stop, [])
  end

  defp api(c, function, args \\ []), do: cluster_call(c.cluster, c.control, Cluster, function, [Instance | args])

  defp child(c, spec) do
    assert {:ok, pid} =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, spec])

    pid
  end

  defp stop_child(c, pid) do
    assert :ok =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, pid])

    refute cluster_call(c.cluster, c.control, Process, :alive?, [pid])
  end
end
