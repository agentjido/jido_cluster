defmodule JidoCluster.Examples.Support.DockerProviderCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually
  alias Jido.Cluster.HostProvider.Docker
  alias Jido.Cluster.HostProvider.Resource
  alias Jido.Cluster.HostProvider.Step
  alias Jido.Cluster.HostRuntime
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.JournalReplyLoss
  alias JidoCluster.Test.{Bedrock, DockerExampleNode, DockerExampleProvider}

  def start(c, topology, opts) do
    {modes, core_mode, restart, provider_id, host_specs} = validated_options(opts)
    [control] = c.cluster.nodes

    workers =
      for _ <- modes, do: String.to_atom(List.to_string(:peer.random_name(~c"jido_provider_example")) <> "@127.0.0.1")

    [worker | _] = workers
    namespace = "docker-example/#{Jido.generate_id()}"
    service = Module.concat(topology, "Cluster")
    jido = Module.concat(service, Core)
    table = shared_table(c.cluster, [control])
    persistence = {Jido.Persistence.Mnesia, table: table}
    cookie = cluster_call(c.cluster, control, Node, :get_cookie, [])

    ExUnit.Callbacks.on_exit(fn ->
      stop_node(c.cluster, control)
      File.rm_rf!(c.tmp_dir)
    end)

    assert {:ok, _} = cluster_call(c.cluster, control, Bedrock, :start, [c.tmp_dir], 40_000)

    core =
      if core_mode == :attached,
        do: child(c, control, {Jido, name: jido, namespace: namespace, persistence: persistence})

    provider = child(c, control, {DockerExampleProvider, []})

    env = [
      "JIDO_CLUSTER_CONTROL_NODE=" <> Atom.to_string(control),
      "JIDO_CLUSTER_COOKIE=" <> Atom.to_string(cookie),
      "JIDO_CLUSTER_TABLE=" <> Atom.to_string(table),
      "JIDO_CLUSTER_CORE=" <> Atom.to_string(jido)
    ]

    transports = transports(c, control, workers, host_specs, opts, provider, env)
    docker = elem(transports[worker], 1).docker
    cluster = %{c.cluster | nodes: [control | workers]} |> Map.put(:transports, transports)
    backend = {Jido.Persistence.Bedrock, repo: Bedrock.Repo}
    faults = if opts[:faults], do: child(c, control, {JournalReplyLoss, backend})
    journal = if faults, do: {JournalReplyLoss, server: faults}, else: backend

    c =
      Map.merge(c, %{
        cluster: cluster,
        control: control,
        worker: worker,
        workers: workers,
        jido: jido,
        service: service,
        namespace: namespace,
        table: table,
        provider: provider,
        docker: docker,
        backend: backend,
        journal: journal,
        faults: faults,
        borrowed: nil,
        cores: if(core, do: [{control, core}], else: []),
        core_mode: core_mode
      })

    # Register before the service can acquire a container. The ledger records
    # steps before effects and survives abrupt scope-owner death.
    ExUnit.Callbacks.on_exit(fn -> cleanup_resources(c) end)

    {host_configs, c} =
      Enum.map_reduce(Enum.zip(workers, modes), c, fn {host, mode}, acc ->
        {next, provider_options, borrowed} = prepare_host(acc, host, mode)
        {{host, %{ownership: mode, options: provider_options, borrowed: borrowed}}, next}
      end)

    host_configs = Map.new(host_configs)
    c = Map.merge(c, %{borrowed: host_configs[worker].borrowed, host_configs: host_configs})
    definition = topology.new!(id: "registry").definition

    options = [
      journal: journal,
      registry: %{
        "schema/v1" => {:schema, definition.schema},
        "recorder/v1" => {:agent, Module.concat(topology, Recorder)},
        "node" => {:atom, :node}
      },
      pools: [
        workers: [
          hosts:
            for(
              {host, spec} <- Enum.zip(workers, host_specs),
              do: %{
                node: host,
                labels: spec.labels,
                capacity: spec.capacity,
                available: true,
                allocation: spec.allocation
              }
            )
        ]
      ],
      host_providers:
        Map.new(host_configs, fn {host, config} ->
          {host, [id: provider_id, adapter: {DockerExampleProvider, config.options}, ownership: config.ownership]}
        end)
    ]

    options =
      if core_mode == :attached,
        do: options ++ [jido: jido],
        else: options ++ [namespace: namespace, agent_persistence: persistence]

    instance = child(c, control, Supervisor.child_spec({service, options}, restart: restart))
    Map.merge(c, %{instance: instance, options: options})
  end

  defp validated_options(opts) do
    assert Keyword.keys(opts) --
             [
               :ownership,
               :worker_namespace,
               :additional_hosts,
               :faults,
               :core_mode,
               :host_specs,
               :restart,
               :provider_id
             ] == []

    ownership = Keyword.get(opts, :ownership, :owned)
    modes = [ownership | Keyword.get(opts, :additional_hosts, [])]
    assert length(modes) in 1..4 and Enum.all?(modes, &(&1 in [:owned, :borrowed]))
    core_mode = Keyword.get(opts, :core_mode, :attached)
    assert core_mode in [:attached, :managed]
    restart = Keyword.get(opts, :restart, :temporary)
    assert restart in [:temporary, :permanent]
    provider_id = Keyword.get(opts, :provider_id, "example-provider")
    assert is_binary(provider_id)

    host_specs =
      Keyword.get(
        opts,
        :host_specs,
        Enum.map(modes, &%{ownership: &1, allocation: "default", capacity: 2, labels: ["compute"]})
      )

    assert length(host_specs) == length(modes)

    for {spec, mode} <- Enum.zip(host_specs, modes) do
      assert %{ownership: ^mode, allocation: allocation, capacity: capacity, labels: labels} = spec
      assert is_binary(allocation) and is_integer(capacity) and capacity in 1..256 and is_list(labels)
    end

    {modes, core_mode, restart, provider_id, host_specs}
  end

  defp transports(c, control, workers, host_specs, opts, provider, env) do
    [worker | _] = workers

    Map.new(Enum.zip(workers, host_specs), fn {host, spec} ->
      environment =
        if host == worker and opts[:worker_namespace],
          do: env ++ ["JIDO_CLUSTER_NAMESPACE=" <> opts[:worker_namespace]],
          else: env

      environment =
        environment ++
          [
            "JIDO_CLUSTER_ALLOCATION=" <> spec.allocation,
            "JIDO_CLUSTER_CAPACITY=" <> Integer.to_string(spec.capacity)
          ]

      container =
        c.docker_options[:container]
        |> Map.put("Env", environment)
        |> Map.put("HostConfig", %{"NetworkMode" => "host"})

      docker = Keyword.put(c.docker_options, :container, container)
      entry = %{cluster: c.cluster, control: control, worker: host, provider: provider, docker: docker}
      {host, {DockerExampleNode, entry}}
    end)
  end

  def resources(c) do
    Enum.flat_map(["default", "external"], fn scope ->
      assert {:ok, resources} = Docker.discover({c.namespace, scope}, 4, c.docker)
      resources
    end)
  end

  defp prepare_host(c, host, :owned), do: {c, [server: c.provider, docker: entry(c, host).docker], nil}

  defp prepare_host(c, host, :borrowed) do
    docker = entry(c, host).docker

    {:ok, step} =
      Step.new(%{
        namespace: c.namespace,
        scope: "external",
        host: Atom.to_string(host),
        provider: "fixture-owner",
        id: Jido.generate_id()
      })

    assert {:ok, resource} =
             cluster_call(
               c.cluster,
               c.control,
               DockerExampleProvider,
               :acquire,
               [step, [server: c.provider, docker: docker]],
               30_000
             )

    boot(%{c | worker: host})
    core = cluster_call(c.cluster, host, Process, :whereis, [c.jido])
    assert is_pid(core)
    borrowed = docker |> Keyword.delete(:container) |> Keyword.put(:borrowed_id, resource.id)
    {%{c | cores: c.cores ++ [{host, core}]}, [server: c.provider, docker: borrowed], resource}
  end

  def provider(c, :resources, []), do: resources(c)

  def provider(c, :replace, [previous]) do
    assert previous.step in provider(c, :steps, [])
    host = host_for(c, previous.step)
    docker = entry(c, host).docker
    assert {:ok, current} = Docker.inspect(previous.step, docker)
    assert Resource.same?(previous, current)
    assert :ok = Docker.release(previous, docker)
    absent_id(c, previous)
    eventually(fn -> host not in cluster_call(c.cluster, c.control, Node, :list, []) end)
    # This is an external fixture replacement, not a repeated scope request.
    assert {:ok, replacement} = Docker.acquire(previous.step, docker)
    boot(%{c | worker: host})
    {:ok, replacement}
  end

  def provider(c, function, args),
    do: cluster_call(c.cluster, c.control, DockerExampleProvider, function, [c.provider | args])

  def effect(c, :release, resource) do
    assert resource.step in provider(c, :steps, [])
    docker = entry(c, host_for(c, resource.step)).docker

    result =
      cluster_call(
        c.cluster,
        c.control,
        DockerExampleProvider,
        :release,
        [resource, [server: c.provider, docker: docker]],
        30_000
      )

    if result == :ok do
      # Inspect the immutable ID. A replacement can have the same step/name,
      # so absence of this ID must not mean absence of that replacement.
      absent_id(c, resource)
    end

    result
  end

  defp absent_id(c, resource) do
    exact = c.docker |> Keyword.delete(:container) |> Keyword.put(:borrowed_id, resource.id)
    eventually(fn -> Docker.inspect(resource.step, exact) == {:ok, :absent} end, timeout: 15_000)
  end

  def stale_release(c, previous) do
    # An old immutable Docker ID is already absent after replacement. Releasing
    # it is idempotent; the scenario separately requires the replacement alive.
    assert :ok = effect(c, :release, previous)
  end

  def if_present(c, resource, fun) do
    case Docker.inspect(resource.step, c.docker) do
      {:ok, :absent} ->
        :ok

      {:ok, current} ->
        assert Resource.same?(resource, current)
        fun.()

      _ ->
        flunk("Docker presence is unknown; connection cleanup is unconfirmed")
    end
  end

  def stopped(c, host, pids) do
    entry = elem(Map.fetch!(c.cluster.transports, host), 1)

    case DockerExampleNode.observe(entry) do
      {:ok, :absent} ->
        for pid <- pids, do: assert(is_pid(pid) and node(pid) == host)
        eventually(fn -> host not in cluster_call(c.cluster, c.control, Node, :list, []) end)

      {:ok, %Resource{}} ->
        for pid <- pids, do: refute(cluster_call(c.cluster, host, Process, :alive?, [pid]))

      _ ->
        flunk("Docker presence is unknown; process cleanup is unconfirmed")
    end
  end

  def boot(c) do
    eventually(
      fn ->
        match?(
          {:ok, %{allocations: _}},
          DockerExampleNode.request(entry(c, c.worker), HostRuntime, :status, [HostRuntime.name(c.jido)], 2_000)
        )
      end,
      timeout: 30_000,
      interval: 100
    )

    assert c.worker in cluster_call(c.cluster, c.control, Node, :list, [])
    assert c.control in cluster_call(c.cluster, c.worker, Node, :list, [])
  end

  def await_host(c, operation) do
    result = H.api(c, :await, [operation.id])
    boot(c)

    case result do
      {:ok, %{phase: :completed}} ->
        result

      {:ok, %{phase: :uncertain}} ->
        # Creation can finish before BEAM bootstrap. Settle the original step
        # through public reconciliation; never repeat the acquire request.
        H.reconcile(c)
        H.api(c, :operation, [operation.id])
    end
  end

  def cleanup(c) do
    assert [] = H.api(c, :claims)
    assert [] = resources(c)
    for step <- provider(c, :steps, []), do: assert({:ok, :absent} = Docker.inspect(step, c.docker))
    eventually(fn -> Enum.all?(c.workers, &(&1 not in cluster_call(c.cluster, c.control, Node, :list, []))) end)
    stop_child(c, c.instance)
    # Removed worker Core processes are covered by exact container absence.
    for {host, core} <- c.cores, host == c.control, do: stop_child(c, core)
    stop_child(c, c.provider)
    if c.faults, do: stop_child(c, c.faults)
    assert :ok = cluster_call(c.cluster, c.control, Bedrock, :stop, [])
  end

  defp cleanup_resources(c) do
    case resources(c) do
      [] ->
        :ok

      resources ->
        steps = provider(c, :steps, [])

        for resource <- resources do
          assert resource.step in steps
          host = host_for(c, resource.step)
          assert :ok = Docker.release(resource, entry(c, host).docker)
          absent_id(c, resource)
        end

        assert [] = resources(c)
    end
  end

  defp entry(c, host), do: elem(Map.fetch!(c.cluster.transports, host), 1)

  defp host_for(c, step) do
    host = Enum.find(c.workers, &(Atom.to_string(&1) == step.host))
    assert host != nil
    host
  end

  defp child(c, host, spec) do
    assert {:ok, pid} =
             cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, spec])

    pid
  end

  defp stop_child(c, pid) do
    assert :ok =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, pid])

    refute cluster_call(c.cluster, c.control, Process, :alive?, [pid])
  end
end
