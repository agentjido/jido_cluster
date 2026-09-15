defmodule JidoCluster.Test.ClusterCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Jido.Cluster.{InstanceManager, Topology}
  import JidoCluster.Test.Eventually

  using opts do
    tag = Keyword.get(opts, :tag, :peer)

    quote do
      @moduletag unquote(tag)
      @moduletag timeout: 60_000
      import JidoCluster.Test.Eventually
      import JidoCluster.Test.ClusterCase
    end
  end

  setup context do
    {_, 0} = System.cmd("epmd", ["-daemon"])
    count = Map.get(context, :cluster_nodes, 2)
    true = is_integer(count) and count in 1..8
    cookie = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false) |> String.to_charlist()

    peers =
      for _ <- 1..count, into: %{} do
        {:ok, peer, worker} =
          :peer.start(%{
            name: :peer.random_name(~c"jido_cluster_test"),
            host: ~c"127.0.0.1",
            longnames: true,
            connection: :standard_io,
            wait_boot: 15_000,
            args: [~c"+S", ~c"2", ~c"-setcookie", cookie, ~c"-kernel", ~c"inet_dist_use_interface", ~c"{127,0,0,1}"]
          })

        # Register cleanup before any application or code-path setup can fail.
        on_exit(fn -> stop_peer(peer) end)
        :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()], 5_000)
        {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:jido_cluster], 10_000)
        :ok = :peer.call(peer, :logger, :set_primary_config, [:level, :warning], 5_000)
        {worker, peer}
      end

    cluster = %{peers: peers, nodes: Enum.sort(Map.keys(peers))}

    for worker <- cluster.nodes, other <- cluster.nodes -- [worker] do
      assert cluster_call(cluster, worker, Node, :connect, [other])
    end

    eventually(
      fn ->
        Enum.all?(cluster.nodes, fn worker ->
          cluster_call(cluster, worker, Topology, :connected_nodes, []) == cluster.nodes
        end)
      end,
      timeout: 5_000
    )

    {:ok, cluster: cluster}
  end

  # The controller map is read locally. Calls use separate peer channels rather
  # than one GenServer that serializes all nodes' requests.
  def cluster_call(cluster, worker, module, function, args, timeout \\ 15_000) do
    :peer.call(Map.fetch!(cluster.peers, worker), module, function, args, timeout)
  end

  def start_nodes(cluster, count) do
    assert length(cluster.nodes) == count,
           "Use @tag cluster_nodes: #{count} to select this test's node count"

    cluster.nodes
  end

  def start_managers(cluster, workers, opts) do
    for worker <- workers, do: assert({:ok, _} = cluster_call(cluster, worker, InstanceManager, :start, [opts]))
  end

  def await_members(cluster, worker, manager, expected) do
    eventually(fn -> cluster_call(cluster, worker, InstanceManager, :members, [manager]) == Enum.sort(expected) end,
      timeout: 5_000
    )
  end

  def shared_table(cluster, n1, n2) do
    assert {:ok, _} = cluster_call(cluster, n1, :mnesia, :change_config, [:extra_db_nodes, [n2]])
    table = :"cluster_records_#{System.unique_integer([:positive])}"

    assert {:atomic, :ok} =
             cluster_call(cluster, n1, :mnesia, :create_table, [
               table,
               [attributes: [:key, :value], ram_copies: [n1, n2]]
             ])

    for worker <- [n1, n2], do: assert(:ok = cluster_call(cluster, worker, :mnesia, :wait_for_tables, [[table], 5_000]))
    table
  end

  def key_on(manager, workers, owner) do
    Enum.find(1..500, fn key -> Topology.owner_node(manager, key, Enum.sort(workers)) == owner end) ||
      raise "No key found for requested owner #{inspect(owner)}"
  end

  def stop_node(cluster, worker), do: stop_peer(Map.fetch!(cluster.peers, worker))

  defp stop_peer(peer) do
    ref = Process.monitor(peer)
    if Process.alive?(peer), do: :peer.stop(peer)
    assert_receive {:DOWN, ^ref, :process, ^peer, _reason}, 5_000
    :ok
  end
end
