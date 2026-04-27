defmodule JidoCluster.Distributed.EphemeralInstanceManagerClusterTest do
  use ExUnitCluster.Case, async: false

  import JidoCluster.Test.Eventually

  alias JidoCluster.KeyRuntime
  alias JidoCluster.Topology

  @timeout 10_000

  @doc false
  def attach_partition_counter(counter_id, stage) do
    event = [:jido_cluster, :partition, stage]
    handler_id = {__MODULE__, counter_id, stage}

    :persistent_term.put({:partition_counter, counter_id, stage}, 0)

    :telemetry.attach(
      handler_id,
      event,
      &__MODULE__.increment_partition_counter/4,
      {counter_id, stage}
    )

    :ok
  end

  @doc false
  def increment_partition_counter(_event, _measurements, _metadata, {id, stage_name}) do
    key = {:partition_counter, id, stage_name}
    current = :persistent_term.get(key, 0)
    :persistent_term.put(key, current + 1)
    :ok
  end

  @doc false
  def read_partition_counter(counter_id, stage) do
    :persistent_term.get({:partition_counter, counter_id, stage}, 0)
  end

  @doc false
  def clear_partition_counter(counter_id, stage) do
    :persistent_term.erase({:partition_counter, counter_id, stage})
    :telemetry.detach({__MODULE__, counter_id, stage})
    :ok
  end

  test "get initializes one primary and one standby runtime", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])
    await_full_mesh(cluster, [n1, n2])

    manager = unique_manager(:ephemeral_boot)
    opts = ephemeral_opts(manager)

    start_managers(cluster, [n1, n2], opts)

    key = "ephemeral-boot-1"
    assert {:ok, primary_pid} = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :get, [manager, key, []])

    summaries =
      eventually(fn ->
        s1 = ExUnitCluster.call(cluster, n1, KeyRuntime, :local_summary, [manager, key])
        s2 = ExUnitCluster.call(cluster, n2, KeyRuntime, :local_summary, [manager, key])

        if is_map(s1) and is_map(s2), do: {s1, s2}, else: false
      end)

    {s1, s2} = summaries
    assert Enum.sort([s1.role, s2.role]) == [:primary, :standby]
    assert node(primary_pid) == s1.primary
    assert s1.primary == s2.primary
  end

  test "call replicates state to the standby before replying", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])
    await_full_mesh(cluster, [n1, n2])

    manager = unique_manager(:ephemeral_call)
    opts = ephemeral_opts(manager)
    start_managers(cluster, [n1, n2], opts)

    key = "ephemeral-call-1"
    signal = Jido.Signal.new!("inc", %{}, source: "/test")

    assert {:ok, agent} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [manager, key, signal, @timeout])

    assert agent.state.count == 1

    {primary_summary, standby_summary} =
      eventually(fn ->
        s1 = ExUnitCluster.call(cluster, n1, KeyRuntime, :local_summary, [manager, key])
        s2 = ExUnitCluster.call(cluster, n2, KeyRuntime, :local_summary, [manager, key])

        if is_map(s1) and is_map(s2) do
          pair =
            case {s1.role, s2.role} do
              {:primary, :standby} -> {s1, s2}
              {:standby, :primary} -> {s2, s1}
              _ -> nil
            end

          if pair, do: pair, else: false
        else
          false
        end
      end)

    assert {:ok, primary_state} =
             ExUnitCluster.call(cluster, node(primary_summary.agent_pid), Jido.AgentServer, :state, [
               primary_summary.agent_pid
             ])

    assert {:ok, standby_state} =
             ExUnitCluster.call(cluster, node(standby_summary.agent_pid), Jido.AgentServer, :state, [
               standby_summary.agent_pid
             ])

    assert primary_state.agent.state.count == 1
    assert standby_state.agent.state.count == 1
    assert standby_summary.seq == 1
  end

  test "replicas zero starts only the primary runtime", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])
    await_full_mesh(cluster, [n1, n2])

    manager = unique_manager(:ephemeral_replicas_zero)
    opts = ephemeral_opts(manager, replication: %{replicas: 0, mode: :sync, promotion_timeout_ms: 750})
    start_managers(cluster, [n1, n2], opts)

    key = "ephemeral-replicas-zero-1"
    assert {:ok, pid} = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :get, [manager, key, []])
    owner = node(pid)
    standby = Enum.find([n1, n2], &(&1 != owner))

    eventually(fn ->
      primary_summary = ExUnitCluster.call(cluster, owner, KeyRuntime, :local_summary, [manager, key])
      standby_summary = ExUnitCluster.call(cluster, standby, KeyRuntime, :local_summary, [manager, key])

      match?(%{role: :primary, standby: nil}, primary_summary) and is_nil(standby_summary)
    end)

    assert %{total: 1, by_node: by_node} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :stats, [manager])

    assert Map.get(by_node, owner, 0) == 1
    assert Map.get(by_node, standby, 0) == 0
  end

  test "cast waits for standby sync before returning", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])
    await_full_mesh(cluster, [n1, n2])

    manager = unique_manager(:ephemeral_cast)
    opts = ephemeral_opts(manager)
    start_managers(cluster, [n1, n2], opts)

    key = "ephemeral-cast-1"
    signal = Jido.Signal.new!("inc", %{}, source: "/test")

    assert :ok = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :cast, [manager, key, signal])

    {primary_summary, standby_summary} =
      eventually(fn ->
        s1 = ExUnitCluster.call(cluster, n1, KeyRuntime, :local_summary, [manager, key])
        s2 = ExUnitCluster.call(cluster, n2, KeyRuntime, :local_summary, [manager, key])

        if is_map(s1) and is_map(s2) do
          pair =
            case {s1.role, s2.role} do
              {:primary, :standby} -> {s1, s2}
              {:standby, :primary} -> {s2, s1}
              _ -> nil
            end

          if pair, do: pair, else: false
        else
          false
        end
      end)

    assert {:ok, primary_state} =
             ExUnitCluster.call(cluster, node(primary_summary.agent_pid), Jido.AgentServer, :state, [
               primary_summary.agent_pid
             ])

    assert {:ok, standby_state} =
             ExUnitCluster.call(cluster, node(standby_summary.agent_pid), Jido.AgentServer, :state, [
               standby_summary.agent_pid
             ])

    assert primary_state.agent.state.count == 1
    assert standby_state.agent.state.count == 1
    assert primary_summary.seq == 1
    assert standby_summary.seq == 1
  end

  test "planned handoff preserves state and moves primary ownership", %{cluster: cluster} do
    [n1] = start_nodes(cluster, 1)
    ensure_apps(cluster, [n1])

    manager = unique_manager(:ephemeral_handoff)
    opts = ephemeral_opts(manager)
    start_managers(cluster, [n1], opts)

    n2 = ExUnitCluster.start_node(cluster)
    ensure_apps(cluster, [n2])
    start_managers(cluster, [n2], opts)
    await_full_mesh(cluster, [n1, n2])

    key = pick_key_owned_by(manager, [n1, n2], n2)
    signal = Jido.Signal.new!("inc", %{}, source: "/test")

    assert {:ok, first} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [manager, key, signal, @timeout])

    assert first.state.count == 1

    assert :ok = ExUnitCluster.call(cluster, n1, JidoCluster.Rebalancer, :trigger_sync, [manager, @timeout])

    eventually(fn ->
      ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :owner_node, [manager, key]) == n2
    end)

    assert {:ok, pid_after} = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :get, [manager, key, []])
    assert node(pid_after) == n2

    assert {:ok, second} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [manager, key, signal, @timeout])

    assert second.state.count == 2
  end

  test "standby promotes after primary node termination with latest acknowledged state", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])
    await_full_mesh(cluster, [n1, n2])

    manager = unique_manager(:ephemeral_failover)
    opts = ephemeral_opts(manager)
    start_managers(cluster, [n1, n2], opts)

    key = pick_key_owned_by(manager, [n1, n2], n1)
    signal = Jido.Signal.new!("inc", %{}, source: "/test")

    assert {:ok, first} =
             ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :call, [manager, key, signal, @timeout])

    assert first.state.count == 1

    assert :ok = ExUnitCluster.stop_node(cluster, n1)

    eventually(fn ->
      ExUnitCluster.call(cluster, n2, Topology, :connected_nodes, []) == [n2]
    end)

    assert {:ok, promoted_pid} = ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :get, [manager, key, []])
    assert node(promoted_pid) == n2

    assert {:ok, promoted_state} = ExUnitCluster.call(cluster, n2, Jido.AgentServer, :state, [promoted_pid])
    assert promoted_state.agent.state.count == 1

    assert {:ok, second} =
             ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :call, [manager, key, signal, @timeout])

    assert second.state.count == 2
  end

  test "freeze policy stops live-transfer runtimes in a minority partition", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])
    await_full_mesh(cluster, [n1, n2])

    manager = unique_manager(:ephemeral_freeze_live_transfer)

    opts =
      ephemeral_opts(manager,
        min_quorum_nodes: 2,
        partition_policy: :freeze,
        replication: %{replicas: 1, mode: :sync, promotion_timeout_ms: 250}
      )

    start_managers(cluster, [n1, n2], opts)

    key = "ephemeral-freeze-live-transfer-1"
    signal = Jido.Signal.new!("inc", %{}, source: "/test")
    counter_id = unique_counter_id(:partition_freeze)

    for node <- [n1, n2], stage <- [:freeze, :unfreeze] do
      assert :ok = ExUnitCluster.call(cluster, node, __MODULE__, :attach_partition_counter, [counter_id, stage])
    end

    assert {:ok, first} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [manager, key, signal, @timeout])

    assert first.state.count == 1

    eventually(fn ->
      s1 = ExUnitCluster.call(cluster, n1, KeyRuntime, :local_summary, [manager, key])
      s2 = ExUnitCluster.call(cluster, n2, KeyRuntime, :local_summary, [manager, key])
      is_map(s1) and is_map(s2)
    end)

    disconnect_nodes(cluster, n1, n2)
    await_topology(cluster, n1, [n1])
    await_topology(cluster, n2, [n2])

    eventually(fn ->
      ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [manager, key, signal, @timeout]) ==
        {:error, :cluster_unavailable}
    end)

    eventually(fn ->
      ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :call, [manager, key, signal, @timeout]) ==
        {:error, :cluster_unavailable}
    end)

    eventually(fn ->
      ExUnitCluster.call(cluster, n1, KeyRuntime, :local_keys, [manager]) == []
    end)

    eventually(fn ->
      ExUnitCluster.call(cluster, n2, KeyRuntime, :local_keys, [manager]) == []
    end)

    for node <- [n1, n2] do
      assert ExUnitCluster.call(cluster, node, __MODULE__, :read_partition_counter, [counter_id, :freeze]) >= 1
    end

    reconnect_nodes(cluster, n1, n2)
    await_full_mesh(cluster, [n1, n2])

    for node <- [n1, n2] do
      eventually(fn ->
        ExUnitCluster.call(cluster, node, __MODULE__, :read_partition_counter, [counter_id, :unfreeze]) >= 1
      end)
    end

    assert {:ok, _after_heal} =
             ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :call, [manager, key, signal, @timeout])

    for node <- [n1, n2], stage <- [:freeze, :unfreeze] do
      assert :ok = ExUnitCluster.call(cluster, node, __MODULE__, :clear_partition_counter, [counter_id, stage])
    end
  end

  test "soft-owner split promotes standby and converges back to one primary on heal", %{cluster: cluster} do
    [n1, n2] = start_nodes(cluster, 2)
    ensure_apps(cluster, [n1, n2])
    await_full_mesh(cluster, [n1, n2])

    manager = unique_manager(:ephemeral_soft_owner)
    opts = ephemeral_opts(manager)
    start_managers(cluster, [n1, n2], opts)

    key = pick_key_owned_by(manager, [n1, n2], n1)
    signal = Jido.Signal.new!("inc", %{}, source: "/test")

    assert {:ok, first} =
             ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :call, [manager, key, signal, @timeout])

    assert first.state.count == 1

    disconnect_nodes(cluster, n1, n2)
    await_topology(cluster, n1, [n1])
    await_topology(cluster, n2, [n2])

    eventually(fn ->
      case ExUnitCluster.call(cluster, n2, KeyRuntime, :local_summary, [manager, key]) do
        %{role: :primary, primary: ^n2, epoch: epoch} when epoch >= 1 -> true
        _ -> false
      end
    end)

    assert {:ok, second} =
             ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :call, [manager, key, signal, @timeout])

    assert second.state.count == 2

    reconnect_nodes(cluster, n1, n2)
    await_full_mesh(cluster, [n1, n2])

    {healed_primary, healed_standby} =
      fn ->
        s1 = safe_cluster_call(cluster, n1, KeyRuntime, :local_summary, [manager, key])
        s2 = safe_cluster_call(cluster, n2, KeyRuntime, :local_summary, [manager, key])

        case {s1, s2} do
          {%{node: primary_node, role: :primary, primary: primary_node, seq: 2},
           %{node: standby_node, role: :standby, primary: primary_node, seq: 2}}
          when primary_node != standby_node ->
            {primary_node, standby_node}

          {%{node: standby_node, role: :standby, primary: primary_node, seq: 2},
           %{node: primary_node, role: :primary, primary: primary_node, seq: 2}}
          when primary_node != standby_node ->
            {primary_node, standby_node}

          _ ->
            false
        end
      end
      |> eventually(timeout: 5_000)

    assert healed_primary == ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :owner_node, [manager, key])
    assert healed_primary == ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :owner_node, [manager, key])

    assert %{total: 1, by_node: by_node} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :stats, [manager])

    assert Map.get(by_node, healed_primary, 0) == 1
    assert Map.get(by_node, healed_standby, 0) == 0
  end

  defp ephemeral_opts(manager, overrides \\ []) do
    base = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: nil,
      rebalance: true,
      rebalance_interval_ms: 120_000,
      max_migrations_per_tick: 1,
      min_quorum_nodes: 1,
      partition_policy: :soft_owner,
      handoff_mode: :live_transfer,
      coordination_backend: :connected_beam,
      replication: %{replicas: 1, mode: :sync, promotion_timeout_ms: 750}
    ]

    Keyword.merge(base, overrides)
  end

  defp ensure_apps(cluster, nodes) do
    Enum.each(nodes, fn node ->
      assert_app_started(ExUnitCluster.call(cluster, node, Application, :ensure_all_started, [:jido]))
      assert_app_started(ExUnitCluster.call(cluster, node, Application, :ensure_all_started, [:jido_cluster]))
    end)
  end

  defp start_nodes(cluster, count) do
    for _ <- 1..count do
      ExUnitCluster.start_node(cluster)
    end
  end

  defp start_managers(cluster, nodes, opts) do
    Enum.each(nodes, fn node ->
      case ExUnitCluster.call(cluster, node, JidoCluster.InstanceManager, :start, [opts]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        other -> raise("Failed to start manager on node #{inspect(node)}: #{inspect(other)}")
      end
    end)
  end

  defp unique_manager(prefix) do
    :"manager_#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp unique_counter_id(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp pick_key_owned_by(manager, nodes, owner) do
    nodes = Enum.sort(nodes)

    Enum.find_value(1..500, fn index ->
      key = "ephemeral-key-#{index}"
      if Topology.owner_node(manager, key, nodes) == owner, do: key, else: nil
    end) || raise("Failed to find key for owner #{inspect(owner)}")
  end

  defp await_full_mesh(cluster, nodes) do
    expected = Enum.sort(nodes)

    eventually(
      fn ->
        Enum.all?(nodes, fn node ->
          ExUnitCluster.call(cluster, node, Topology, :connected_nodes, []) == expected
        end)
      end,
      timeout: 5_000
    )
  end

  defp await_topology(cluster, node, expected_nodes) do
    expected = Enum.sort(expected_nodes)

    eventually(
      fn ->
        ExUnitCluster.call(cluster, node, Topology, :connected_nodes, []) == expected
      end,
      timeout: 5_000
    )
  end

  defp disconnect_nodes(cluster, left, right) do
    assert ExUnitCluster.call(cluster, left, Node, :disconnect, [right]) in [true, false]
    assert ExUnitCluster.call(cluster, right, Node, :disconnect, [left]) in [true, false]
    :ok
  end

  defp reconnect_nodes(cluster, left, right) do
    assert ExUnitCluster.call(cluster, left, Node, :connect, [right]) in [true, false]
    eventually(fn -> right in ExUnitCluster.call(cluster, left, Node, :list, []) end)
    :ok
  end

  defp safe_cluster_call(cluster, node, module, function, args) do
    ExUnitCluster.call(cluster, node, module, function, args)
  catch
    :exit, _reason -> :error
  end

  defp assert_app_started(:ok), do: :ok
  defp assert_app_started({:ok, apps}) when is_list(apps), do: :ok
  defp assert_app_started(other), do: raise("Failed to start app on cluster node: #{inspect(other)}")
end
