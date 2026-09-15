defmodule Jido.Cluster.Examples.KeyedCounterDemo do
  alias Jido.Cluster.Examples.KeyedCounter
  alias Jido.Cluster.{InstanceManager, Topology}

  def run do
    {_, 0} = System.cmd("epmd", ["-daemon"])
    cookie = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false) |> String.to_charlist()
    {p1, n1} = boot(cookie)

    try do
      {p2, n2} = boot(cookie)

      try do
        result = exercise(p1, n1, p2, n2)
        stop(p2)
        stop(p1)

        IO.inspect(Map.put(result, :nodes_stopped, not Process.alive?(p1) and not Process.alive?(p2)),
          label: "Keyed counter result"
        )
      after
        stop(p2)
      end
    after
      stop(p1)
    end
  end

  defp boot(cookie) do
    {:ok, peer, worker} =
      :peer.start(%{
        name: :peer.random_name(~c"jido_cluster_example"),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        wait_boot: 15_000,
        args: [~c"+S", ~c"2", ~c"-setcookie", cookie, ~c"-kernel", ~c"inet_dist_use_interface", ~c"{127,0,0,1}"]
      })

    try do
      :ok = rpc(peer, :code, :add_paths, [:code.get_path()])
      {:ok, _} = rpc(peer, Application, :ensure_all_started, [:jido_cluster])
      :ok = rpc(peer, :logger, :set_primary_config, [:level, :warning])
      {peer, worker}
    rescue
      error ->
        stop(peer)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        stop(peer)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp exercise(p1, n1, p2, n2) do
    true = rpc(p1, Node, :connect, [n2])
    true = rpc(p2, Node, :connect, [n1])
    {:ok, _} = rpc(p1, :mnesia, :change_config, [:extra_db_nodes, [n2]])
    table = :keyed_counter_example_records
    {:atomic, :ok} = rpc(p1, :mnesia, :create_table, [table, [attributes: [:key, :value], ram_copies: [n1, n2]]])
    for peer <- [p1, p2], do: :ok = rpc(peer, :mnesia, :wait_for_tables, [[table], 5_000])
    manager = Jido.Cluster.Examples.CounterManager

    opts = [
      name: manager,
      agent: KeyedCounter,
      namespace: "examples/cluster/keyed-counter",
      persistence: {Jido.Cluster.Storage.Mnesia, table: table}
    ]

    for peer <- [p1, p2], do: {:ok, _} = rpc(peer, InstanceManager, :start, [opts])
    workers = Enum.sort([n1, n2])
    for peer <- [p1, p2], do: await(fn -> rpc(peer, InstanceManager, :members, [manager]) == workers end)
    key = Enum.find(1..500, fn key -> Topology.owner_node(manager, key, workers) == n2 end)
    {:ok, %{state: %{count: 1}}} = rpc(p1, InstanceManager, :call, [manager, key, KeyedCounter.increment_signal!()])
    {:ok, %{state: %{count: 3}}} = rpc(p2, InstanceManager, :call, [manager, key, KeyedCounter.increment_signal!(2)])
    {:ok, old} = rpc(p1, InstanceManager, :lookup, [manager, key])
    ^n2 = node(old)
    stop(p2)
    await(fn -> rpc(p1, InstanceManager, :members, [manager]) == [n1] end)
    {:ok, restored} = rpc(p1, InstanceManager, :get, [manager, key])
    ^n1 = node(restored)
    %{agent: %{state: %{count: 3}}, state_version: 2} = rpc(p1, Jido.AgentServer, :snapshot, [restored])
    {:ok, %{state: %{count: 4}}} = rpc(p1, InstanceManager, :call, [manager, key, KeyedCounter.increment_signal!()])
    %{state_version: 3} = rpc(p1, Jido.AgentServer, :snapshot, [restored])
    %{count_before_loss: 3, recovered_count: 3, final_count: 4, state_version: 3}
  end

  defp rpc(peer, module, function, args), do: :peer.call(peer, module, function, args, 15_000)

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 5_000)

  defp await(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "Cluster membership did not converge"

      true ->
        :timer.sleep(20)
        await(fun, deadline)
    end
  end

  defp stop(peer) do
    if Process.alive?(peer) do
      ref = Process.monitor(peer)
      :peer.stop(peer)

      receive do
        {:DOWN, ^ref, :process, ^peer, _} -> :ok
      after
        5_000 -> raise "Peer did not stop"
      end
    end

    :ok
  end
end

Jido.Cluster.Examples.KeyedCounterDemo.run()
