defmodule JidoCluster.Examples.Support.SystemLifecycleCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually
  alias Jido.Cluster
  alias Jido.Cluster.Examples.DeploymentLifecycle
  alias Jido.Cluster.HostProvider.Step

  alias JidoCluster.Examples.Support.{
    DockerSystemLifecycleCase,
    FederationLifecycleCase,
    HostProviderCase,
    JournalReplyLoss
  }

  alias JidoCluster.Test.{Bedrock, HostProvider}

  def start(c, mode, opts \\ [])
  def start(%{docker_options: _} = c, mode, opts), do: DockerSystemLifecycleCase.start(c, mode, opts)

  def start(c, mode, opts) do
    [control, source, target, independent] = c.cluster.nodes
    topology = Keyword.get(opts, :topology, DeploymentLifecycle)
    service = Module.concat(topology, "Cluster")
    jido = Module.concat(service, Core)
    namespace = "system-lifecycle/#{Jido.generate_id()}"
    table = shared_table(c.cluster, c.cluster.nodes)
    persistence = {Jido.Persistence.Mnesia, table: table}

    on_exit = fn ->
      stop_node(c.cluster, control)
      File.rm_rf!(c.tmp_dir)
    end

    ExUnit.Callbacks.on_exit(on_exit)
    assert {:ok, _} = cluster_call(c.cluster, control, Bedrock, :start, [c.tmp_dir], 40_000)
    backend = {Jido.Persistence.Bedrock, repo: Bedrock.Repo}
    faults = child(c, control, {JournalReplyLoss, backend})
    external = if mode == :attached, do: c.cluster.nodes, else: c.cluster.nodes -- [control]

    cores =
      for host <- external,
          do: {host, child(c, host, {Jido, name: jido, namespace: namespace, persistence: persistence})}

    hosts = [
      %{node: source, labels: ["shared"], capacity: 2, available: true, allocation: "shared"},
      %{node: target, labels: ["shared"], capacity: 2, available: true, allocation: "shared"},
      %{node: independent, labels: ["independent"], capacity: 1, available: true, allocation: "independent"}
    ]

    {guards, provider, provider_config, borrowed} = host_setup(c, jido, namespace, hosts, opts[:providers])

    registry = %{
      "schema/v1" => {:schema, topology.new!(id: "registry").definition.schema},
      "recorder/v1" => {:agent, Module.concat(topology, Recorder)},
      "node" => {:atom, :node}
    }

    options = [journal: {JournalReplyLoss, server: faults}, registry: registry, pools: [workers: [hosts: hosts]]]
    options = if provider, do: Keyword.put(options, :host_providers, provider_config), else: options

    options =
      if mode == :attached,
        do: Keyword.put(options, :jido, jido),
        else: options ++ [namespace: namespace, agent_persistence: persistence]

    instance = child(c, control, {service, options})
    core = cluster_call(c.cluster, control, Process, :whereis, [jido])

    c =
      Map.merge(c, %{
        control: control,
        source: source,
        target: target,
        independent: independent,
        service: service,
        jido: jido,
        namespace: namespace,
        backend: backend,
        faults: faults,
        cores: cores,
        guards: guards,
        instance: instance,
        core: core,
        options: options,
        mode: mode,
        topology: topology,
        provider: provider,
        provider_resources: nil,
        borrowed: borrowed
      })

    if provider, do: accept_providers(c), else: c
  end

  defp host_setup(c, jido, _namespace, hosts, value) when value in [nil, false] do
    guards =
      for host <- hosts,
          do:
            {host.node,
             child(c, host.node, {Cluster.HostRuntime, jido: jido, allocations: %{host.allocation => host.capacity}})}

    {guards, nil, %{}, nil}
  end

  defp host_setup(c, jido, namespace, hosts, true) do
    [control | _] = c.cluster.nodes
    provider = child(c, control, {HostProvider, []})
    independent = List.last(hosts)

    {:ok, step} =
      Step.new(%{
        namespace: namespace,
        scope: "external",
        host: Atom.to_string(independent.node),
        provider: "fixture-owner",
        id: "borrowed"
      })

    {:ok, borrowed} = cluster_call(c.cluster, control, HostProvider, :acquire, [step, [server: provider]])
    guard = child(c, independent.node, {Cluster.HostRuntime, jido: jido, allocations: %{"independent" => 1}})

    config =
      Map.new(hosts, fn host ->
        borrowed? = host.node == independent.node
        runtime = {host.node, [jido: jido, allocations: %{host.allocation => host.capacity}]}

        options =
          if borrowed?,
            do: [server: provider, borrowed_id: borrowed.id],
            else: [server: provider, host_runtime: runtime]

        {host.node,
         [
           id: "system-provider",
           adapter: {HostProvider, options},
           ownership: if(borrowed?, do: :borrowed, else: :owned)
         ]}
      end)

    {[{independent.node, guard}], provider, config, borrowed}
  end

  defp accept_providers(c) do
    for host <- [c.source, c.target, c.independent] do
      {:ok, operation} = api(c, :acquire_host, [host, [request_id: api(c, :request_id)]])
      assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])
      assert {:ok, %{admission: :open, session: %{phase: :ready}}} = api(c, :host_status, [host])
    end

    guards =
      for host <- [c.source, c.target, c.independent] do
        pid = cluster_call(c.cluster, host, Process, :whereis, [Cluster.HostRuntime.name(c.jido)])
        assert is_pid(pid)
        {host, pid}
      end

    %{c | guards: guards, provider_resources: provider(c, :resources)}
  end

  def provider_checkpoint(%{provider: nil}), do: :ok

  def provider_checkpoint(c) do
    assert Enum.sort(provider(c, :resources)) == Enum.sort(c.provider_resources)
    calls = provider(c, :calls)
    assert Enum.count(calls, &match?({:acquire, _}, &1)) == 3
    refute Enum.any?(calls, &match?({:release, _}, &1))
    :ok
  end

  def api(c, function, args \\ [])
  def api(%{docker: _} = c, function, args), do: HostProviderCase.api(c, function, args)
  def api(c, function, args), do: FederationLifecycleCase.api(c, function, args)
  defdelegate mirror(c, activation, host), to: FederationLifecycleCase
  defdelegate retired(c, mirror), to: FederationLifecycleCase
  defdelegate delivered(c, id, agent, signal, expected), to: FederationLifecycleCase
  defdelegate events(c, agent), to: FederationLifecycleCase

  def deploy(c, module, prefix, target) do
    topology =
      Enum.find_value(1..100, fn n ->
        candidate = module.new!(id: "#{prefix}-#{n}")

        case api(c, :plan, [candidate]) do
          {:ok, %{placements: %{"listener" => ^target}}} -> candidate
          _ -> nil
        end
      end)

    assert topology != nil,
           inspect(%{
             plan: api(c, :plan, [module.new!(id: "diagnostic")]),
             connected: cluster_call(c.cluster, c.control, Node, :list, []),
             target: target,
             status: api(c, :status),
             claims: api(c, :claims)
           })

    {:ok, operation} = api(c, :deploy, [topology, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])
    {:ok, ref} = api(c, :ref, [topology.id, :listener])
    {:ok, %{pid: agent}} = api(c, :lookup, [ref])
    assert node(agent) == target
    %{id: topology.id, ref: ref, agent: agent, operation: operation.id}
  end

  def stop(c, d) do
    {:ok, %{activation: activation}} = api(c, :status, [d.id])
    {:ok, %{channels: [channel]}} = api(c, :federation_status, [d.id])
    mirrors = for host <- channel.hosts, do: mirror(c, activation, host.host)
    {:ok, %{pid: agent}} = api(c, :lookup, [d.ref])
    {:ok, op} = api(c, :stop, [d.id, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [op.id])
    for mirror <- mirrors, do: retired(c, mirror)
    refute cluster_call(c.cluster, node(agent), Process, :alive?, [agent])
    op.id
  end

  def recover(c) do
    assert :ok = api(c, :reconcile)
    eventually(fn -> not api(c, :status).recovering end, timeout: 30_000)
  end

  def child(c, host, spec) do
    {:ok, pid} = cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, spec])
    pid
  end

  def stop_child(c, host, pid) do
    assert :ok = cluster_call(c.cluster, host, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, pid])
    refute cluster_call(c.cluster, host, Process, :alive?, [pid])
  end

  def finish(%{docker: _} = c), do: DockerSystemLifecycleCase.finish(c)

  def finish(c) do
    assert [] = api(c, :claims)
    release_providers(c)
    current_core = cluster_call(c.cluster, c.control, Process, :whereis, [c.jido])
    stop_child(c, c.control, c.instance)
    assert cluster_call(c.cluster, c.control, Process, :alive?, [current_core]) == (c.mode == :attached)
    for {host, pid} <- c.cores, do: assert(cluster_call(c.cluster, host, Process, :alive?, [pid]))
    for {host, pid} <- c.guards ++ c.cores, do: stop_child(c, host, pid)
    cleanup_provider(c)
    stop_child(c, c.control, c.faults)
    assert :ok = cluster_call(c.cluster, c.control, Bedrock, :stop, [])
  end

  def release_providers(%{provider: nil}), do: :ok

  def release_providers(c) do
    provider_checkpoint(c)

    for host <- [c.source, c.target, c.independent] do
      {:ok, operation} = api(c, :release_host, [host, [request_id: api(c, :request_id)]])
      assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])
      phase = if host == c.independent, do: :retained, else: :released
      assert {:ok, %{admission: :closed, session: %{phase: ^phase}}} = api(c, :host_status, [host])
    end

    assert provider(c, :resources) == [c.borrowed]
    releases = for {:release, resource} <- provider(c, :calls), do: resource.step.host
    assert Enum.sort(releases) == Enum.sort(Enum.map([c.source, c.target], &Atom.to_string/1))
    {_, guard} = Enum.find(c.guards, &(elem(&1, 0) == c.independent))
    assert cluster_call(c.cluster, c.independent, Process, :alive?, [guard])
    {:ok, journal} = cluster_call(c.cluster, c.control, Cluster.Journal, :open, [c.backend, {c.namespace, "default"}])
    assert Enum.sort(Enum.map(journal.record["host_sessions"], & &1["phase"])) == ["released", "released", "retained"]
  end

  defp cleanup_provider(%{provider: nil}), do: :ok

  defp cleanup_provider(c) do
    assert :ok = cluster_call(c.cluster, c.control, HostProvider, :release, [c.borrowed, [server: c.provider]])
    assert [] = provider(c, :resources)
    stop_child(c, c.control, c.provider)
  end

  defp provider(%{docker: _} = c, function), do: HostProviderCase.provider(c, function)
  defp provider(c, function), do: cluster_call(c.cluster, c.control, HostProvider, function, [c.provider])

  def reconnect_cleanup(%{docker: _} = c, source, cookie),
    do: DockerSystemLifecycleCase.reconnect_cleanup(c, source, cookie)

  def reconnect_cleanup(c, source, cookie), do: reconnect(c, source, cookie)

  def disconnect(c, source) do
    for peer <- c.cluster.nodes -- [source] do
      cluster_call(c.cluster, peer, Node, :set_cookie, [source, :system_control_partition])
      cluster_call(c.cluster, source, Node, :set_cookie, [peer, :system_source_partition])
      cluster_call(c.cluster, peer, Node, :disconnect, [source])
    end

    for peer <- c.cluster.nodes -- [source],
        other <- c.cluster.nodes -- [source, peer],
        do: assert(cluster_call(c.cluster, peer, Node, :connect, [other]))

    eventually(fn ->
      Enum.all?(c.cluster.nodes -- [source], &(source not in cluster_call(c.cluster, &1, Node, :list, [])))
    end)
  end

  def reconnect(c, source, cookie) do
    for peer <- c.cluster.nodes -- [source] do
      cluster_call(c.cluster, peer, Node, :set_cookie, [source, cookie])
      cluster_call(c.cluster, source, Node, :set_cookie, [peer, cookie])
    end

    if Map.has_key?(c, :docker) do
      reconnect_docker(c)
    else
      reconnect_native(c, source)
    end
  end

  defp reconnect_native(c, source) do
    for peer <- c.cluster.nodes -- [source], do: assert(cluster_call(c.cluster, peer, Node, :connect, [source]))
    eventually(fn -> mesh?(c, c.cluster.nodes) end)
  end

  defp reconnect_docker(c) do
    eventually(
      fn ->
        connect_group(c, c.cluster.nodes)
        mesh?(c, c.cluster.nodes)
      end,
      timeout: 30_000,
      interval: 100
    )

    stable_docker_group(c, c.cluster.nodes)
  end

  def connect_independent_group(c, isolated) do
    connected = c.cluster.nodes -- [isolated]

    connect_group(c, connected, true)

    for peer <- connected, do: assert(:ok = cluster_call(c.cluster, peer, :global, :sync, []))

    eventually(
      fn ->
        mesh?(c, connected)
      end,
      timeout: if(Map.has_key?(c, :docker), do: 30_000, else: 2_000)
    )

    if Map.has_key?(c, :docker), do: stable_docker_group(c, connected)
  end

  defp stable_docker_group(c, connected) do
    deadline = System.monotonic_time(:millisecond) + 30_000
    stable_docker_group(c, connected, nil, deadline)
  end

  defp stable_docker_group(c, connected, since, deadline) do
    now = System.monotonic_time(:millisecond)
    observed = group_observation(c, connected)

    assert now < deadline, "Docker worker group did not stabilize during partition: #{inspect(observed)}"

    visible? = Enum.all?(observed, fn {peer, status} -> Enum.sort(status.nodes) == Enum.sort(connected -- [peer]) end)
    tables? = visible? and Enum.all?(observed, fn {_, status} -> status.table == :ok end)

    if tables? and since != nil and now - since >= 1_500 do
      :ok
    else
      continue_stabilizing(c, connected, since, deadline, tables?, now)
    end
  end

  defp continue_stabilizing(c, connected, since, deadline, tables?, now) do
    if not tables? do
      connect_group(c, connected, true)
      for peer <- connected, do: assert(:ok = cluster_call(c.cluster, peer, :global, :sync, []))
    end

    receive do
    after
      100 -> stable_docker_group(c, connected, if(tables?, do: since || now, else: nil), deadline)
    end
  end

  defp connect_group(c, connected, strict? \\ false) do
    for peer <- connected,
        other <- connected -- [peer] do
      result = cluster_call(c.cluster, peer, Node, :connect, [other])
      if strict?, do: assert(result)
      result
    end
  end

  defp mesh?(c, connected) do
    Enum.all?(connected, fn peer ->
      Enum.sort(cluster_call(c.cluster, peer, Node, :list, [])) == Enum.sort(connected -- [peer])
    end)
  end

  defp group_observation(c, connected) do
    for peer <- connected do
      {peer,
       %{
         nodes: cluster_call(c.cluster, peer, Node, :list, []),
         table: cluster_call(c.cluster, peer, :mnesia, :wait_for_tables, [[c.table], 100])
       }}
    end
  end
end
