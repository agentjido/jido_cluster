defmodule JidoCluster.InstanceManagerTest do
  use ExUnit.Case, async: false

  alias Jido.Cluster.{Config, InstanceManager}
  alias JidoCluster.Test.CounterAgent
  import JidoCluster.Test.Eventually

  setup do
    manager = :"v3_manager_#{System.unique_integer([:positive])}"
    table = :"v3_persistence_#{System.unique_integer([:positive])}"
    assert {:atomic, :ok} = :mnesia.create_table(table, attributes: [:key, :value], ram_copies: [node()])
    on_exit(fn -> :mnesia.delete_table(table) end)
    opts = [name: manager, agent: CounterAgent, persistence: {Jido.Cluster.Storage.Mnesia, table: table}]
    start_supervised!({InstanceManager, opts})
    %{manager: manager, opts: opts}
  end

  test "the runtime uses Jido V3" do
    assert Application.spec(:jido, :vsn) |> to_string() |> String.starts_with?("3.")
    assert Application.spec(:jido_action, :vsn) |> to_string() |> String.starts_with?("3.")
    assert Application.spec(:jido_signal, :vsn) |> to_string() |> String.starts_with?("3.")
  end

  test "concurrent starts return one keyed activation", %{manager: manager} do
    results =
      1..8
      |> Task.async_stream(fn _ -> InstanceManager.get(manager, {:account, "one"}) end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)

    assert length(Enum.uniq(results)) == 1
    assert %{total: 1, errors: %{}} = InstanceManager.stats(manager)
  end

  test "calls commit a V3 Agent and its revision", %{manager: manager} do
    assert {:ok, agent} = InstanceManager.call(manager, "one", signal())
    assert %Jido.Agent{module: CounterAgent, state: %{count: 1}} = agent
    assert {:ok, pid} = InstanceManager.lookup(manager, "one")
    assert %{agent: ^agent, state_version: 1} = Jido.AgentServer.snapshot(pid)
    assert InstanceManager.owner_node(manager, "one") == node()
    assert InstanceManager.members(manager) == [node()]
  end

  test "stop and restart restore the committed checkpoint and revision", %{manager: manager} do
    assert {:ok, _} = InstanceManager.call(manager, {:tenant, 7}, signal())
    assert {:ok, _} = InstanceManager.call(manager, {:tenant, 7}, signal())
    assert :ok = InstanceManager.stop(manager, {:tenant, 7})
    assert :error = InstanceManager.lookup(manager, {:tenant, 7})
    assert {:ok, pid} = InstanceManager.get(manager, {:tenant, 7})
    assert %{agent: %{state: %{count: 2}}, state_version: 2} = Jido.AgentServer.snapshot(pid)
    assert {:ok, %{state: %{count: 3}}} = InstanceManager.call(manager, {:tenant, 7}, signal())
  end

  test "a killed activation is restored on the next manager call", %{manager: manager} do
    assert {:ok, _} = InstanceManager.call(manager, "crash", signal())
    assert {:ok, old} = InstanceManager.lookup(manager, "crash")
    Process.exit(old, :kill)
    eventually(fn -> InstanceManager.lookup(manager, "crash") == :error end)
    assert {:ok, %{state: %{count: 2}}} = InstanceManager.call(manager, "crash", signal())
    assert {:ok, fresh} = InstanceManager.lookup(manager, "crash")
    refute fresh == old
  end

  test "cast enqueues work without a commit acknowledgment", %{manager: manager} do
    assert :ok = InstanceManager.cast(manager, "cast", signal())
    assert {:ok, pid} = InstanceManager.lookup(manager, "cast")
    eventually(fn -> Jido.AgentServer.snapshot(pid).agent.state.count == 1 end)
  end

  test "manager shutdown stops its agents and releases membership", %{manager: manager} do
    assert {:ok, pid} = InstanceManager.get(manager, "shutdown")
    stop_supervised!({InstanceManager, manager})
    eventually(fn -> not Process.alive?(pid) and InstanceManager.members(manager) == [] end)
    assert {:error, :manager_unavailable} = InstanceManager.get(manager, "shutdown")
  end

  test "quorum rejects work when too few manager nodes are present" do
    name = :"v3_quorum_#{System.unique_integer([:positive])}"
    start_supervised!({InstanceManager, name: name, agent: CounterAgent, min_quorum_nodes: 2})
    assert {:error, :cluster_unavailable} = InstanceManager.call(name, "one", signal())
    assert %{total: 0} = InstanceManager.stats(name)
  end

  test "invalid keys, Signals, timeouts, and V2 options are rejected", %{manager: manager} do
    assert {:error, :invalid_key} = InstanceManager.get(manager, self())
    assert {:error, :invalid_signal} = InstanceManager.call(manager, "one", %{})
    assert {:error, :invalid_timeout} = InstanceManager.call(manager, "one", signal(), 0)
    assert {:error, :invalid_get_options} = InstanceManager.get(manager, "one", storage: :old)
    assert {:error, :invalid_manager_options} = Config.new(name: manager, agent: CounterAgent, storage: :old)

    assert {:error, :invalid_manager_options} =
             Config.new(name: manager, agent: CounterAgent, handoff_mode: :live_transfer)

    assert {:error, :invalid_manager_options} =
             Config.new(name: manager, agent: CounterAgent, agent_opts: [id: "other"])
  end

  test "portable key identity is stable and preserves key types" do
    assert InstanceManager.agent_id(%{a: 1, b: 2}) == InstanceManager.agent_id(%{b: 2, a: 1})
    refute InstanceManager.agent_id(1) == InstanceManager.agent_id("1")
    refute InstanceManager.agent_id({:tenant, 1}) == InstanceManager.agent_id([:tenant, 1])
  end

  defp signal, do: Jido.Signal.new!("inc", %{}, source: "/test/v3")
end
