defmodule JidoCluster.Examples.Support.DockerSystemLifecycleCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually
  alias Jido.Cluster.HostProvider.Docker
  alias Jido.Cluster.HostProvider.Resource
  alias Jido.Cluster.HostRuntime
  alias JidoCluster.Examples.Support.DockerProviderCase, as: D
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.SystemLifecycleCase, as: S
  alias JidoCluster.Test.Bedrock

  def start(c, mode, opts) do
    assert mode in [:attached, :managed]
    assert opts[:providers] == true
    topology = Keyword.fetch!(opts, :topology)

    specs = [
      %{ownership: :owned, labels: ["shared"], allocation: "shared", capacity: 2},
      %{ownership: :owned, labels: ["shared"], allocation: "shared", capacity: 2},
      %{ownership: :borrowed, labels: ["independent"], allocation: "independent", capacity: 1}
    ]

    c =
      D.start(c, topology,
        additional_hosts: [:owned, :borrowed],
        host_specs: specs,
        core_mode: mode,
        restart: :permanent,
        provider_id: "system-provider",
        faults: true
      )

    [source, target, independent] = c.workers
    core = cluster_call(c.cluster, c.control, Process, :whereis, [c.jido])
    assert is_pid(core)

    c =
      Map.merge(c, %{
        source: source,
        target: target,
        independent: independent,
        core: core,
        mode: mode,
        topology: topology,
        borrowed: c.host_configs[independent].borrowed
      })

    for host <- c.workers do
      {:ok, operation} = H.api(c, :acquire_host, [host, [request_id: H.api(c, :request_id)]])
      assert {:ok, %{phase: :completed}} = D.await_host(%{c | worker: host}, operation)
      assert {:ok, %{admission: :open, session: %{phase: :ready}}} = H.api(c, :host_status, [host])
    end

    for host <- c.workers do
      assert {:atomic, :ok} =
               cluster_call(c.cluster, c.control, :mnesia, :add_table_copy, [c.table, host, :ram_copies])

      assert :ok = cluster_call(c.cluster, host, :mnesia, :wait_for_tables, [[c.table], 5_000])
    end

    guards =
      for host <- c.workers do
        pid = cluster_call(c.cluster, host, Process, :whereis, [HostRuntime.name(c.jido)])
        assert is_pid(pid)
        {host, pid}
      end

    worker_cores =
      for host <- c.workers do
        pid = cluster_call(c.cluster, host, Process, :whereis, [c.jido])
        assert is_pid(pid)
        {host, pid}
      end

    resources = D.resources(c)
    assert length(resources) == 3
    assert Enum.sort(Enum.map(resources, & &1.step.host)) == Enum.sort(Enum.map(c.workers, &Atom.to_string/1))
    Map.merge(c, %{guards: guards, provider_resources: resources, worker_cores: worker_cores})
  end

  def finish(c) do
    assert [] = S.api(c, :claims)
    S.release_providers(c)

    for host <- [c.source, c.target] do
      {_, guard} = Enum.find(c.guards, &(elem(&1, 0) == host))
      {_, core} = Enum.find(c.worker_cores, &(elem(&1, 0) == host))
      D.stopped(c, host, [guard, core])
    end

    current_core = cluster_call(c.cluster, c.control, Process, :whereis, [c.jido])
    assert is_pid(current_core)
    S.stop_child(c, c.control, c.instance)
    assert cluster_call(c.cluster, c.control, Process, :alive?, [current_core]) == (c.mode == :attached)

    for {host, pid} <- c.cores,
        do: assert(cluster_call(c.cluster, host, Process, :alive?, [pid]))

    {_, borrowed_core} = Enum.find(c.worker_cores, &(elem(&1, 0) == c.independent))
    {_, borrowed_guard} = Enum.find(c.guards, &(elem(&1, 0) == c.independent))
    assert cluster_call(c.cluster, c.independent, Process, :alive?, [borrowed_core])
    assert cluster_call(c.cluster, c.independent, Process, :alive?, [borrowed_guard])
    assert D.resources(c) == [c.borrowed]

    # The external fixture owner performs this final deletion after the scope
    # has proved that it retained the borrowed container and its processes.
    assert :ok = D.effect(c, :release, c.borrowed)
    D.stopped(c, c.independent, [borrowed_core, borrowed_guard])
    assert [] = D.resources(c)
    for step <- D.provider(c, :steps, []), do: assert({:ok, :absent} = Docker.inspect(step, c.docker))

    eventually(fn ->
      Enum.all?(c.workers, &(&1 not in cluster_call(c.cluster, c.control, Node, :list, [])))
    end)

    if c.mode == :attached, do: S.stop_child(c, c.control, current_core)
    S.stop_child(c, c.control, c.provider)
    S.stop_child(c, c.control, c.faults)
    assert :ok = cluster_call(c.cluster, c.control, Bedrock, :stop, [])
  end

  def reconnect_cleanup(c, source, cookie) do
    observed =
      for resource <- c.provider_resources do
        case Docker.inspect(resource.step, c.docker) do
          {:ok, :absent} ->
            nil

          {:ok, current} ->
            assert Resource.same?(resource, current)
            resource.step.host

          _ ->
            flunk("Docker presence is unknown; partition cleanup is unconfirmed")
        end
      end

    present = Enum.reject(observed, &is_nil/1)

    if Atom.to_string(source) in present do
      nodes = [c.control | Enum.filter(c.workers, &(Atom.to_string(&1) in present))]
      S.reconnect(%{c | cluster: %{c.cluster | nodes: nodes}}, source, cookie)
    end
  end
end
