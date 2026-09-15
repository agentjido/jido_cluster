defmodule Jido.Cluster.Examples.Topologies.LocalNodes do
  @moduledoc "Loopback Erlang hosts for the executable Topology lessons."
  alias Jido.Cluster.Examples.Topologies.Definition
  alias Jido.Topology.Controller

  @doc "Runs a lesson on isolated hosts and stops every host on success or failure."
  @spec run(pos_integer(), (map() -> map())) :: map()
  def run(count, lesson) do
    {_, 0} = System.cmd("epmd", ["-daemon"])
    cookie = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false) |> String.to_charlist()

    {result, peers} =
      with_peers(count, cookie, [], fn peers ->
        context = configure(peers)
        {lesson.(context), peers}
      end)

    result = Map.put(result, :nodes_stopped, Enum.all?(peers, fn {peer, _node} -> not Process.alive?(peer) end))
    IO.inspect(result, label: "Topology example result")
    result
  end

  @doc "Calls a public API on one host over its independent control channel."
  @spec call(map(), node(), module(), atom(), list()) :: term()
  def call(context, worker, module, function, args),
    do: :peer.call(Map.fetch!(context.peers, worker), module, function, args, 15_000)

  @doc "Builds and starts a manually repaired core Controller on the first host."
  @spec start(map(), module(), map()) :: {pid(), Jido.Topology.Instance.t()}
  def start(context, module, placements) do
    first = hd(context.nodes)
    {:ok, instance} = call(context, first, Definition, :build, [module, context.id, placements])

    {:ok, controller} =
      call(context, first, DynamicSupervisor, :start_child, [
        Jido.Cluster.ManagerSupervisor,
        {Controller, jido: context.jido, topology: instance, repair: :manual}
      ])

    :ok = call(context, first, Controller, :await_ready, [controller, 10_000])
    {controller, instance}
  end

  @doc "Stops a host and waits for its controller process to exit."
  @spec stop_host(map(), node()) :: :ok
  def stop_host(context, worker), do: stop_peer(Map.fetch!(context.peers, worker))

  @doc "Waits for a public state condition with a bounded deadline."
  @spec await((-> boolean())) :: :ok
  def await(condition), do: await(condition, System.monotonic_time(:millisecond) + 5_000)

  defp with_peers(0, _cookie, peers, lesson), do: lesson.(Enum.reverse(peers))

  defp with_peers(count, cookie, peers, lesson) do
    {:ok, peer, worker} =
      :peer.start(%{
        name: :peer.random_name(~c"jido_topology_example"),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        wait_boot: 15_000,
        args: [~c"+S", ~c"2", ~c"-setcookie", cookie, ~c"-kernel", ~c"inet_dist_use_interface", ~c"{127,0,0,1}"]
      })

    try do
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:jido_cluster], 10_000)
      :ok = :peer.call(peer, :logger, :set_primary_config, [:level, :warning])
      with_peers(count - 1, cookie, [{peer, worker} | peers], lesson)
    after
      stop_peer(peer)
    end
  end

  defp configure(peers) do
    context = %{
      peers: Map.new(peers, fn {peer, worker} -> {worker, peer} end),
      nodes: Enum.map(peers, &elem(&1, 1)),
      jido: Jido.Cluster.Examples.TopologyRuntime,
      id: "local-topology",
      namespace: "examples/local-topology"
    }

    for worker <- context.nodes,
        other <- context.nodes -- [worker],
        do: true = call(context, worker, Node, :connect, [other])

    [first | rest] = context.nodes
    {:ok, _} = call(context, first, :mnesia, :change_config, [:extra_db_nodes, rest])
    table = :topology_example_records

    {:atomic, :ok} =
      call(context, first, :mnesia, :create_table, [table, [attributes: [:key, :value], ram_copies: context.nodes]])

    for worker <- context.nodes do
      :ok = call(context, worker, :mnesia, :wait_for_tables, [[table], 5_000])

      {:ok, _} =
        call(context, worker, DynamicSupervisor, :start_child, [
          Jido.Cluster.ManagerSupervisor,
          {Jido,
           name: context.jido, namespace: context.namespace, persistence: {Jido.Cluster.Storage.Mnesia, table: table}}
        ])
    end

    context
  end

  defp await(condition, deadline) do
    cond do
      condition.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "Public state condition did not converge"

      true ->
        :timer.sleep(20)
        await(condition, deadline)
    end
  end

  defp stop_peer(peer) do
    if Process.alive?(peer) do
      ref = Process.monitor(peer)
      :peer.stop(peer)

      receive do
        {:DOWN, ^ref, :process, ^peer, _reason} -> :ok
      after
        5_000 -> raise "Example host did not stop"
      end
    end

    :ok
  end
end
