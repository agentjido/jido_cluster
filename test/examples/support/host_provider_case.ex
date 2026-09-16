defmodule JidoCluster.Examples.Support.HostProviderCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually
  alias Jido.Cluster
  alias Jido.Cluster.Federation.Mirror
  alias Jido.Cluster.HostProvider.Step
  alias Jido.Cluster.HostRuntime
  alias JidoCluster.Examples.Support.DockerProviderCase
  alias JidoCluster.Examples.Support.JournalReplyLoss
  alias JidoCluster.Test.{Bedrock, HostProvider}

  def start(c, topology, opts \\ [])
  def start(%{docker_options: _} = c, topology, opts), do: DockerProviderCase.start(c, topology, opts)

  def start(c, topology, opts) do
    [control, worker | extra_workers] = c.cluster.nodes
    workers = [worker | extra_workers]
    ownership = Keyword.get(opts, :ownership, :owned)
    extra_modes = Keyword.get(opts, :additional_hosts, [])
    assert length(extra_modes) == length(extra_workers)
    service = Module.concat(topology, "Cluster")
    jido = Module.concat(service, Core)
    namespace = "host-provider/#{Jido.generate_id()}"
    table = shared_table(c.cluster, c.cluster.nodes)
    persistence = {Jido.Persistence.Mnesia, table: table}

    ExUnit.Callbacks.on_exit(fn ->
      stop_node(c.cluster, control)
      File.rm_rf!(c.tmp_dir)
    end)

    assert {:ok, _} = cluster_call(c.cluster, control, Bedrock, :start, [c.tmp_dir], 40_000)
    backend = {Jido.Persistence.Bedrock, repo: Bedrock.Repo}
    faults = if opts[:faults], do: child(c, control, {JournalReplyLoss, backend})
    journal = if faults, do: {JournalReplyLoss, server: faults}, else: backend

    cores =
      for host <- c.cluster.nodes,
          do:
            {host,
             child(
               c,
               host,
               {Jido,
                name: jido,
                namespace: if(host == worker, do: opts[:worker_namespace] || namespace, else: namespace),
                persistence: persistence}
             )}

    provider = child(c, control, {HostProvider, []})

    host_configs =
      for {host, mode} <- Enum.zip(workers, [ownership | extra_modes]), into: %{} do
        {options, borrowed} = provider_options(c, control, host, jido, namespace, provider, mode)
        {host, %{ownership: mode, options: options, borrowed: borrowed}}
      end

    definition = topology.new!(id: "registry").definition

    options = [
      jido: jido,
      journal: journal,
      registry: %{
        "schema/v1" => {:schema, definition.schema},
        "recorder/v1" => {:agent, Module.concat(topology, Recorder)},
        "node" => {:atom, :node}
      },
      pools: [
        workers: [hosts: for(host <- workers, do: %{node: host, labels: ["compute"], capacity: 2, available: true})]
      ],
      host_providers:
        Map.new(host_configs, fn {host, config} ->
          {host, [id: "example-provider", adapter: {HostProvider, config.options}, ownership: config.ownership]}
        end)
    ]

    instance = child(c, control, Supervisor.child_spec({service, options}, restart: :temporary))

    Map.merge(c, %{
      control: control,
      worker: worker,
      workers: workers,
      service: service,
      jido: jido,
      namespace: namespace,
      journal: journal,
      backend: backend,
      faults: faults,
      provider: provider,
      borrowed: host_configs[worker].borrowed,
      host_configs: host_configs,
      options: options,
      instance: instance,
      cores: cores
    })
  end

  defp provider_options(_c, _control, worker, jido, _namespace, provider, :owned),
    do: {[server: provider, host_runtime: {worker, [jido: jido]}], nil}

  defp provider_options(c, control, worker, jido, namespace, provider, :borrowed) do
    {:ok, step} =
      Step.new(%{
        namespace: namespace,
        scope: "external",
        host: Atom.to_string(worker),
        provider: "fixture-owner",
        id: "prepared"
      })

    {:ok, resource} = cluster_call(c.cluster, control, HostProvider, :acquire, [step, [server: provider]])
    child(c, worker, {HostRuntime, jido: jido})
    {[server: provider, borrowed_id: resource.id], resource}
  end

  def api(c, function, args \\ [])

  def api(%{docker: _} = c, function, args) do
    args = if function == :await and length(args) == 1, do: args ++ [30_000], else: args
    cluster_call(c.cluster, c.control, Cluster, function, [c.service | args], 45_000)
  end

  def api(c, function, args), do: cluster_call(c.cluster, c.control, Cluster, function, [c.service | args])

  def provider(c, function, args \\ [])
  def provider(%{docker: _} = c, function, args), do: DockerProviderCase.provider(c, function, args)

  def provider(c, function, args),
    do: cluster_call(c.cluster, c.control, HostProvider, function, [c.provider | args])

  def acquire(c) do
    {:ok, operation} = api(c, :acquire_host, [c.worker, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = await_host(c, operation)
    operation
  end

  def await_host(%{docker: _} = c, operation), do: DockerProviderCase.await_host(c, operation)
  def await_host(c, operation), do: api(c, :await, [operation.id])

  def effect(%{docker: _} = c, function, resource), do: DockerProviderCase.effect(c, function, resource)

  def effect(c, function, resource),
    do: cluster_call(c.cluster, c.control, HostProvider, function, [resource, [server: c.provider]])

  def stale_release(%{docker: _} = c, resource), do: DockerProviderCase.stale_release(c, resource)
  def stale_release(c, resource), do: assert({:error, {:rejected, :stale_resource}} = effect(c, :release, resource))

  def if_present(%{docker: _} = c, resource, fun), do: DockerProviderCase.if_present(c, resource, fun)
  def if_present(_c, _resource, fun), do: fun.()

  def stopped(c, host, pids) do
    if Map.has_key?(Map.get(c.cluster, :transports, %{}), host),
      do: DockerProviderCase.stopped(c, host, pids),
      else: Enum.each(pids, fn pid -> refute(cluster_call(c.cluster, host, Process, :alive?, [pid])) end)
  end

  def deploy(c, topology) do
    {:ok, operation} = api(c, :deploy, [topology, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])
    deployment(c, topology.id)
  end

  def deployment(c, id) do
    {:ok, ref} = api(c, :ref, [id, :listener])
    {:ok, %{pid: agent}} = api(c, :lookup, [ref])
    assert node(agent) == c.worker
    {:ok, %{activation: activation}} = api(c, :status, [id])

    mirrors =
      for host <- [c.control, c.worker] do
        assert {:ok, pid} = cluster_call(c.cluster, host, Mirror, :lookup, [c.jido, activation, "events"])
        status = cluster_call(c.cluster, host, Mirror, :status, [pid])
        %{host: host, pid: pid, components: Map.values(status.components)}
      end

    %{id: id, agent: agent, ref: ref, mirrors: mirrors}
  end

  def delivered(c, deployment, signal, expected) do
    assert {:ok, _} = api(c, :publish, [deployment.id, :events, signal])

    eventually(fn ->
      snapshot = cluster_call(c.cluster, c.worker, Jido.AgentServer, :snapshot, [deployment.agent])
      snapshot.agent.state.events == expected
    end)
  end

  def stop(c, deployment) do
    {:ok, operation} = api(c, :stop, [deployment.id, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])
    refute cluster_call(c.cluster, c.worker, Process, :alive?, [deployment.agent])

    for mirror <- deployment.mirrors,
        pid <- [mirror.pid | mirror.components],
        do: refute(cluster_call(c.cluster, mirror.host, Process, :alive?, [pid]))

    refute Enum.any?(api(c, :claims), &(&1.topology_id == deployment.id))
  end

  def release(c) do
    {:ok, operation} = api(c, :release_host, [c.worker, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])
    assert [] = provider(c, :resources)
    assert {:ok, %{admission: :closed, session: %{phase: :released}}} = api(c, :host_status, [c.worker])
  end

  def restart_owner(c) do
    if Map.has_key?(c, :docker), do: DockerProviderCase.boot(c)
    name = Cluster.Instance.name(c.service, Service)
    owner = cluster_call(c.cluster, c.control, Process, :whereis, [name])
    assert is_pid(owner)
    assert true = cluster_call(c.cluster, c.control, Process, :exit, [owner, :kill])
    eventually(fn -> not cluster_call(c.cluster, c.control, Process, :alive?, [c.instance]) end)
    refute cluster_call(c.cluster, c.control, Process, :alive?, [owner])
    assert {:ok, _} = cluster_call(c.cluster, c.control, Bedrock, :restart, [], 40_000)
    instance = child(c, c.control, Supervisor.child_spec({c.service, c.options}, restart: :temporary))
    %{c | instance: instance}
  end

  def reconcile(c) do
    assert :ok = api(c, :reconcile)
    timeout = if Map.has_key?(c, :docker), do: 30_000, else: 2_000
    eventually(fn -> not api(c, :status).recovering end, timeout: timeout)
  end

  def record(c) do
    assert {:ok, journal} =
             cluster_call(c.cluster, c.control, Cluster.Journal, :open, [c.backend, {c.namespace, "default"}])

    journal.record
  end

  def cleanup(%{docker: _} = c), do: DockerProviderCase.cleanup(c)

  def cleanup(c) do
    assert [] = api(c, :claims)
    assert [] = provider(c, :resources)
    stop_child(c, c.control, c.instance)

    for worker <- c.workers do
      guard = cluster_call(c.cluster, worker, Process, :whereis, [HostRuntime.name(c.jido)])
      if is_pid(guard), do: stop_child(c, worker, guard)
    end

    for {host, pid} <- c.cores, do: stop_child(c, host, pid)
    stop_child(c, c.control, c.provider)
    if c.faults, do: stop_child(c, c.control, c.faults)
    assert :ok = cluster_call(c.cluster, c.control, Bedrock, :stop, [])
  end

  defp child(c, host, spec) do
    assert {:ok, pid} =
             cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, spec])

    pid
  end

  defp stop_child(c, host, pid) do
    assert :ok = cluster_call(c.cluster, host, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, pid])
    refute cluster_call(c.cluster, host, Process, :alive?, [pid])
  end
end
