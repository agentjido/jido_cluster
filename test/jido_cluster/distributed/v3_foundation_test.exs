defmodule JidoCluster.Distributed.V3FoundationTest do
  use ExUnitCluster.Case, async: false
  import JidoCluster.Test.Eventually

  alias Jido.Cluster.{InstanceManager, Topology}
  alias JidoCluster.Test.CounterAgent

  @moduletag timeout: 60_000

  test "only manager nodes own keys and callers on both nodes get one activation", %{cluster: cluster} do
    [n1, n2, observer] = nodes(cluster, 3)
    name = unique(:v3_members)
    start_managers(cluster, [n1, n2], name: name, agent: CounterAgent)

    eventually(fn -> cluster_call(cluster, n1, InstanceManager, :members, [name]) == Enum.sort([n1, n2]) end)
    refute observer in cluster_call(cluster, n1, InstanceManager, :members, [name])
    key = {:tenant, "one"}

    results =
      [n1, n2, n1, n2]
      |> Task.async_stream(
        fn worker ->
          cluster_call(cluster, worker, InstanceManager, :get, [name, key])
        end,
        timeout: 20_000
      )
      |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)

    assert length(Enum.uniq(results)) == 1
    assert node(hd(results)) == Topology.owner_node(name, key, Enum.sort([n1, n2]))
    assert {:ok, %{state: %{count: 1}}} = cluster_call(cluster, n1, InstanceManager, :call, [name, key, signal()])
    assert {:ok, %{state: %{count: 2}}} = cluster_call(cluster, n2, InstanceManager, :call, [name, key, signal()])
    assert %{total: 1, errors: %{}} = cluster_call(cluster, n1, InstanceManager, :stats, [name])

    counts =
      [n1, n2, n1, n2]
      |> Task.async_stream(
        fn worker ->
          cluster_call(cluster, worker, InstanceManager, :call, [name, key, signal()])
        end,
        timeout: 20_000
      )
      |> Enum.map(fn {:ok, {:ok, agent}} -> agent.state.count end)

    assert Enum.sort(counts) == [3, 4, 5, 6]
  end

  test "a new placement owner stops the old activation and restores shared state", %{cluster: cluster} do
    [n1, n2] = nodes(cluster, 2)
    table = shared_table(cluster, n1, n2)
    name = unique(:v3_handoff)
    opts = [name: name, agent: CounterAgent, persistence: {Jido.Cluster.Storage.Mnesia, table: table}]
    start_managers(cluster, [n1], opts)
    await_members(cluster, n1, name, [n1])
    key = key_on(name, [n1, n2], n2)
    assert {:ok, %{state: %{count: 1}}} = cluster_call(cluster, n1, InstanceManager, :call, [name, key, signal()])
    assert {:ok, old} = cluster_call(cluster, n1, InstanceManager, :lookup, [name, key])
    assert node(old) == n1

    stop_key =
      Enum.find(501..1_000, fn candidate -> Topology.owner_node(name, candidate, Enum.sort([n1, n2])) == n2 end)

    assert {:ok, stop_pid} = cluster_call(cluster, n1, InstanceManager, :get, [name, stop_key])
    start_managers(cluster, [n2], opts)
    await_members(cluster, n1, name, [n1, n2])
    assert {:ok, fresh} = cluster_call(cluster, n1, InstanceManager, :get, [name, key])
    assert node(fresh) == n2
    refute cluster_call(cluster, n1, Process, :alive?, [old])

    assert %{agent: %{state: %{count: 1}}, state_version: 1} =
             cluster_call(cluster, n2, Jido.AgentServer, :snapshot, [fresh])

    assert :ok = cluster_call(cluster, n2, InstanceManager, :stop, [name, stop_key])
    refute cluster_call(cluster, n1, Process, :alive?, [stop_pid])
    assert %{total: 1} = cluster_call(cluster, n1, InstanceManager, :stats, [name])
  end

  test "owner loss restores the committed V3 checkpoint from replicated Mnesia", %{cluster: cluster} do
    [n1, n2] = nodes(cluster, 2)
    table = shared_table(cluster, n1, n2)
    name = unique(:v3_recovery)
    opts = [name: name, agent: CounterAgent, persistence: {Jido.Cluster.Storage.Mnesia, table: table}]
    start_managers(cluster, [n1, n2], opts)
    await_members(cluster, n1, name, [n1, n2])
    key = key_on(name, [n1, n2], n2)

    assert {:ok, %{state: %{count: 1}}} = cluster_call(cluster, n1, InstanceManager, :call, [name, key, signal()])
    assert {:ok, %{state: %{count: 2}}} = cluster_call(cluster, n1, InstanceManager, :call, [name, key, signal()])
    assert {:ok, old} = cluster_call(cluster, n1, InstanceManager, :lookup, [name, key])
    assert node(old) == n2
    assert :ok = ExUnitCluster.stop_node(cluster, n2)
    await_members(cluster, n1, name, [n1])

    assert {:ok, fresh} = cluster_call(cluster, n1, InstanceManager, :get, [name, key])
    assert node(fresh) == n1

    assert %{agent: %{state: %{count: 2}}, state_version: 2} =
             cluster_call(cluster, n1, Jido.AgentServer, :snapshot, [fresh])

    assert {:ok, %{state: %{count: 3}}} = cluster_call(cluster, n1, InstanceManager, :call, [name, key, signal()])
  end

  test "loss of manager quorum stops local activations and rejects work", %{cluster: cluster} do
    [n1, n2] = nodes(cluster, 2)
    name = unique(:v3_quorum)
    start_managers(cluster, [n1, n2], name: name, agent: CounterAgent, min_quorum_nodes: 2)
    await_members(cluster, n1, name, [n1, n2])
    key = key_on(name, [n1, n2], n1)
    assert {:ok, pid} = cluster_call(cluster, n1, InstanceManager, :get, [name, key])
    assert node(pid) == n1
    assert :ok = ExUnitCluster.stop_node(cluster, n2)
    await_members(cluster, n1, name, [n1])
    eventually(fn -> not cluster_call(cluster, n1, Process, :alive?, [pid]) end)
    assert {:error, :cluster_unavailable} = cluster_call(cluster, n1, InstanceManager, :call, [name, key, signal()])
    assert %{total: 0} = cluster_call(cluster, n1, InstanceManager, :stats, [name])
  end

  test "different manager configurations reject work before activation", %{cluster: cluster} do
    [n1, n2] = nodes(cluster, 2)
    name = unique(:v3_config)
    start_managers(cluster, [n1], name: name, agent: CounterAgent, namespace: "one/#{name}")
    start_managers(cluster, [n2], name: name, agent: CounterAgent, namespace: "two/#{name}")
    await_members(cluster, n1, name, [n1, n2])
    assert {:error, :incompatible_manager_config} = cluster_call(cluster, n1, InstanceManager, :get, [name, "one"])
    assert %{total: 0} = cluster_call(cluster, n1, InstanceManager, :stats, [name])
  end

  defp nodes(cluster, count) do
    workers = for _ <- 1..count, do: ExUnitCluster.start_node(cluster)

    for worker <- workers do
      assert {:ok, _} = cluster_call(cluster, worker, Application, :ensure_all_started, [:jido_cluster])
      for other <- workers -- [worker], do: assert(cluster_call(cluster, worker, Node, :connect, [other]))
    end

    eventually(fn ->
      Enum.all?(workers, fn worker ->
        cluster_call(cluster, worker, Topology, :connected_nodes, []) == Enum.sort(workers)
      end)
    end)

    workers
  end

  defp start_managers(cluster, workers, opts) do
    for worker <- workers, do: assert({:ok, _} = cluster_call(cluster, worker, InstanceManager, :start, [opts]))
  end

  defp await_members(cluster, worker, manager, expected) do
    eventually(fn -> cluster_call(cluster, worker, InstanceManager, :members, [manager]) == Enum.sort(expected) end)
  end

  defp shared_table(cluster, n1, n2) do
    assert {:ok, _} = cluster_call(cluster, n1, :mnesia, :change_config, [:extra_db_nodes, [n2]])
    table = unique(:v3_shared)

    assert {:atomic, :ok} =
             cluster_call(cluster, n1, :mnesia, :create_table, [
               table,
               [attributes: [:key, :value], ram_copies: [n1, n2]]
             ])

    for worker <- [n1, n2], do: assert(:ok = cluster_call(cluster, worker, :mnesia, :wait_for_tables, [[table], 5_000]))
    table
  end

  defp key_on(manager, workers, owner) do
    Enum.find(1..500, fn key -> Topology.owner_node(manager, key, Enum.sort(workers)) == owner end)
  end

  defp cluster_call(cluster, worker, module, function, args),
    do: ExUnitCluster.call(cluster, worker, module, function, args, 15_000)

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
  defp signal, do: Jido.Signal.new!("inc", %{}, source: "/test/v3/cluster")
end
