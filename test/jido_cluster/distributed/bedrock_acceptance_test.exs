defmodule JidoCluster.Distributed.BedrockAcceptanceTest do
  # covers: jido_cluster.acceptance.bedrock_shared_storage_handoff
  # covers: jido_cluster.acceptance.bedrock_stale_owner_release
  # covers: jido_cluster.acceptance.bedrock_owner_loss_failover
  # covers: jido_cluster.acceptance.bedrock_restart_recovery
  # covers: jido_cluster.acceptance.bedrock_keyed_fleet_rebalance
  use ExUnitCluster.Case, async: false
  use JidoCluster.Test.RealBedrockClusterCase

  import JidoCluster.Test.Eventually

  alias JidoCluster.Topology

  @moduletag :real_bedrock
  @moduletag timeout: 60_000

  test "rebalancer hands off a singleton through real Bedrock storage", %{
    cluster: cluster,
    tmp_dir: tmp_dir,
    bedrock_prefix: bedrock_prefix
  } do
    [n1] = start_nodes(cluster, 1)
    n2 = ExUnitCluster.start_node(cluster, join: false)
    ensure_apps(cluster, [n1, n2])
    write_descriptor!(tmp_dir, [n1])
    assert :ok = boot_server_node!(cluster, n1, tmp_dir)
    assert :ok = ExUnitCluster.call(cluster, n1, __MODULE__, :repo_put, ["server-smoke", "ready"])
    assert {:ok, "ready"} = ExUnitCluster.call(cluster, n1, __MODULE__, :repo_get, ["server-smoke"])

    manager = unique_manager(:bedrock_handoff)
    key = handoff_key(manager, Enum.sort([n1, n2]), n2)
    signal = Jido.Signal.new!("inc", %{}, source: "/test")

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: {JidoCluster.Storage.Bedrock, storage_opts(bedrock_prefix)},
      rebalance: true,
      rebalance_interval_ms: 120_000,
      max_migrations_per_tick: 1,
      min_quorum_nodes: 1,
      partition_policy: :freeze
    ]

    start_managers(cluster, [n1], opts)

    assert manager_tree_ready?(ExUnitCluster.call(cluster, n1, __MODULE__, :manager_tree_snapshot, [manager]))

    first_call =
      ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [
        manager,
        key,
        signal,
        10_000
      ])

    {:ok, first} =
      case first_call do
        {:ok, first} ->
          {:ok, first}

        other ->
          flunk("""
          first durable call failed
          result: #{inspect(other, pretty: true, limit: :infinity)}
          n1 tree: #{inspect(ExUnitCluster.call(cluster, n1, __MODULE__, :manager_tree_snapshot, [manager]), pretty: true, limit: :infinity)}
          n2 tree: #{inspect(ExUnitCluster.call(cluster, n2, __MODULE__, :manager_tree_snapshot, [manager]), pretty: true, limit: :infinity)}
          """)
      end

    assert first.state.count == 1

    reconnect_nodes(cluster, n1, n2)
    await_full_mesh(cluster, [n1, n2])
    assert :ok = boot_client_node!(cluster, n2, tmp_dir)
    start_managers(cluster, [n2], opts)

    leader = Topology.leader_node(Enum.sort([n1, n2]))
    assert :ok = ExUnitCluster.call(cluster, leader, JidoCluster.Rebalancer, :trigger_sync, [manager, 10_000])

    eventually(
      fn ->
        case ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :lookup, [manager, key]) do
          {:ok, pid} -> node(pid) == n2
          _ -> false
        end
      end,
      timeout: 10_000
    )

    eventually(
      fn ->
        ExUnitCluster.call(cluster, n1, Jido.Agent.InstanceManager, :lookup, [manager, key]) == :error
      end,
      timeout: 10_000
    )

    assert {:ok, second} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert second.state.count == 2
    assert ExUnitCluster.call(cluster, n2, __MODULE__, :bedrock_key_count, [bedrock_prefix]) > 0

    assert %{total: 1} = ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :stats, [manager])
  end

  test "owner loss after Bedrock-backed handoff rehydrates on the surviving node", %{
    cluster: cluster,
    tmp_dir: tmp_dir,
    bedrock_prefix: bedrock_prefix
  } do
    [n1] = start_nodes(cluster, 1)
    n2 = ExUnitCluster.start_node(cluster, join: false)
    ensure_apps(cluster, [n1, n2])
    write_descriptor!(tmp_dir, [n1])
    assert :ok = boot_server_node!(cluster, n1, tmp_dir)
    assert :ok = ExUnitCluster.call(cluster, n1, __MODULE__, :repo_put, ["server-smoke", "ready"])
    assert {:ok, "ready"} = ExUnitCluster.call(cluster, n1, __MODULE__, :repo_get, ["server-smoke"])

    manager = unique_manager(:bedrock_failover)
    key = handoff_key(manager, Enum.sort([n1, n2]), n2)
    signal = Jido.Signal.new!("inc", %{}, source: "/test")

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: {JidoCluster.Storage.Bedrock, storage_opts(bedrock_prefix)},
      rebalance: true,
      rebalance_interval_ms: 120_000,
      max_migrations_per_tick: 1,
      min_quorum_nodes: 1,
      partition_policy: :freeze
    ]

    start_managers(cluster, [n1], opts)

    assert {:ok, first} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert first.state.count == 1

    reconnect_nodes(cluster, n1, n2)
    await_full_mesh(cluster, [n1, n2])
    assert :ok = boot_client_node!(cluster, n2, tmp_dir)
    start_managers(cluster, [n2], opts)

    leader = Topology.leader_node(Enum.sort([n1, n2]))
    assert :ok = ExUnitCluster.call(cluster, leader, JidoCluster.Rebalancer, :trigger_sync, [manager, 10_000])

    eventually(
      fn ->
        case ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :lookup, [manager, key]) do
          {:ok, pid} -> node(pid) == n2
          _ -> false
        end
      end,
      timeout: 10_000
    )

    assert {:ok, second} =
             ExUnitCluster.call(cluster, n2, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert second.state.count == 2

    assert :ok = ExUnitCluster.stop_node(cluster, n2)

    eventually(
      fn ->
        ExUnitCluster.call(cluster, n1, Topology, :connected_nodes, []) == [n1]
      end,
      timeout: 10_000
    )

    assert {:ok, recovered_pid} = ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :get, [manager, key, []])
    assert node(recovered_pid) == n1

    assert {:ok, recovered_state} = ExUnitCluster.call(cluster, n1, Jido.AgentServer, :state, [recovered_pid])
    assert recovered_state.agent.state.count == 2

    assert {:ok, third} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert third.state.count == 3

    assert %{total: 1, by_node: %{^n1 => 1}} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :stats, [manager])
  end

  test "manager restart rehydrates singleton state from Bedrock", %{
    cluster: cluster,
    tmp_dir: tmp_dir,
    bedrock_prefix: bedrock_prefix
  } do
    [n1] = start_nodes(cluster, 1)
    ensure_apps(cluster, [n1])
    write_descriptor!(tmp_dir, [n1])
    assert :ok = boot_server_node!(cluster, n1, tmp_dir)
    assert :ok = ExUnitCluster.call(cluster, n1, __MODULE__, :repo_put, ["server-smoke", "ready"])
    assert {:ok, "ready"} = ExUnitCluster.call(cluster, n1, __MODULE__, :repo_get, ["server-smoke"])

    manager = unique_manager(:bedrock_restart)
    key = "bedrock-restart-1"
    signal = Jido.Signal.new!("inc", %{}, source: "/test")
    recovery_counter = unique_counter_id(:bedrock_restart_recovery)

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: {JidoCluster.Storage.Bedrock, storage_opts(bedrock_prefix)},
      rebalance: false,
      min_quorum_nodes: 1,
      partition_policy: :freeze
    ]

    start_managers(cluster, [n1], opts)

    assert {:ok, first} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert first.state.count == 1

    assert :ok = ExUnitCluster.stop_node(cluster, n1)

    [n1_restarted] = start_nodes(cluster, 1)
    ensure_apps(cluster, [n1_restarted])
    write_descriptor!(tmp_dir, [n1_restarted])
    assert :ok = boot_server_node!(cluster, n1_restarted, tmp_dir)

    start_managers(cluster, [n1_restarted], opts)

    assert :ok =
             ExUnitCluster.call(cluster, n1_restarted, __MODULE__, :attach_recovery_counter, [recovery_counter, :start])

    assert :ok =
             ExUnitCluster.call(cluster, n1_restarted, __MODULE__, :attach_recovery_counter, [
               recovery_counter,
               :success
             ])

    assert {:ok, pid} =
             ExUnitCluster.call(cluster, n1_restarted, JidoCluster.InstanceManager, :get, [manager, key, []])

    assert node(pid) == n1_restarted

    eventually(
      fn ->
        ExUnitCluster.call(cluster, n1_restarted, __MODULE__, :read_recovery_counter, [recovery_counter, :start]) >= 1 and
          ExUnitCluster.call(cluster, n1_restarted, __MODULE__, :read_recovery_counter, [recovery_counter, :success]) >=
            1
      end,
      timeout: 10_000
    )

    assert {:ok, restored_state} =
             ExUnitCluster.call(cluster, n1_restarted, Jido.AgentServer, :state, [pid])

    assert restored_state.agent.state.count == 1

    assert {:ok, second} =
             ExUnitCluster.call(cluster, n1_restarted, JidoCluster.InstanceManager, :call, [
               manager,
               key,
               signal,
               10_000
             ])

    assert second.state.count == 2

    assert :ok =
             ExUnitCluster.call(cluster, n1_restarted, __MODULE__, :clear_recovery_counter, [recovery_counter, :start])

    assert :ok =
             ExUnitCluster.call(cluster, n1_restarted, __MODULE__, :clear_recovery_counter, [recovery_counter, :success])
  end

  test "real Bedrock keyed fleet rebalances across two nodes without losing per-key state", %{
    cluster: cluster,
    tmp_dir: tmp_dir,
    bedrock_prefix: bedrock_prefix
  } do
    [n1] = start_nodes(cluster, 1)
    n2 = ExUnitCluster.start_node(cluster, join: false)
    ensure_apps(cluster, [n1, n2])
    write_descriptor!(tmp_dir, [n1])
    assert :ok = boot_server_node!(cluster, n1, tmp_dir)
    assert :ok = ExUnitCluster.call(cluster, n1, __MODULE__, :repo_put, ["server-smoke", "ready"])
    assert {:ok, "ready"} = ExUnitCluster.call(cluster, n1, __MODULE__, :repo_get, ["server-smoke"])

    manager = unique_manager(:bedrock_fleet)
    signal = Jido.Signal.new!("inc", %{}, source: "/test")

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: {JidoCluster.Storage.Bedrock, storage_opts(bedrock_prefix)},
      rebalance: true,
      rebalance_interval_ms: 120_000,
      max_migrations_per_tick: 8,
      min_quorum_nodes: 1,
      partition_policy: :freeze
    ]

    keys_for_n1 = pick_keys_owned_by(manager, Enum.sort([n1, n2]), n1, 2)
    keys_for_n2 = pick_keys_owned_by(manager, Enum.sort([n1, n2]), n2, 2)
    all_keys = keys_for_n1 ++ keys_for_n2

    start_managers(cluster, [n1], opts)

    Enum.each(all_keys, fn key ->
      assert {:ok, agent} =
               ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :call, [
                 manager,
                 key,
                 signal,
                 10_000
               ])

      assert agent.state.count == 1
    end)

    reconnect_nodes(cluster, n1, n2)
    await_full_mesh(cluster, [n1, n2])
    assert :ok = boot_client_node!(cluster, n2, tmp_dir)
    start_managers(cluster, [n2], opts)

    leader = Topology.leader_node(Enum.sort([n1, n2]))
    assert :ok = ExUnitCluster.call(cluster, leader, JidoCluster.Rebalancer, :trigger_sync, [manager, 10_000])

    expected_owners =
      Map.new(all_keys, fn key ->
        {key, Topology.owner_node(manager, key, Enum.sort([n1, n2]))}
      end)

    eventually(
      fn ->
        Enum.all?(expected_owners, fn {key, expected_owner} ->
          case ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :lookup, [manager, key]) do
            {:ok, pid} -> node(pid) == expected_owner
            _ -> false
          end
        end)
      end,
      timeout: 10_000
    )

    Enum.each(all_keys, fn key ->
      assert ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :owner_node, [manager, key]) ==
               Map.fetch!(expected_owners, key)
    end)

    Enum.each(all_keys, fn key ->
      caller = Map.fetch!(expected_owners, key)

      assert {:ok, agent} =
               ExUnitCluster.call(cluster, caller, JidoCluster.InstanceManager, :call, [
                 manager,
                 key,
                 signal,
                 10_000
               ])

      assert agent.state.count == 2
    end)

    assert %{total: 4, by_node: %{^n1 => 2, ^n2 => 2}} =
             ExUnitCluster.call(cluster, n1, JidoCluster.InstanceManager, :stats, [manager])
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

  defp reconnect_nodes(cluster, left, right) do
    assert ExUnitCluster.call(cluster, left, Node, :connect, [right]) in [true, false]
    assert ExUnitCluster.call(cluster, right, Node, :connect, [left]) in [true, false]
    :ok
  end

  defp handoff_key(manager, nodes, target_node) do
    Enum.find_value(1..500, fn idx ->
      key = "bedrock-handoff-#{idx}"

      if Topology.owner_node(manager, key, nodes) == target_node do
        key
      end
    end) || raise "failed to find a key owned by #{inspect(target_node)}"
  end

  defp pick_keys_owned_by(manager, nodes, target_node, count) do
    1..5_000
    |> Stream.map(&"bedrock-fleet-#{&1}")
    |> Stream.filter(&(Topology.owner_node(manager, &1, nodes) == target_node))
    |> Enum.take(count)
  end

  defp unique_manager(prefix) do
    :"manager_#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp unique_counter_id(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  def attach_recovery_counter(counter_id, stage) do
    event = [:jido_cluster, :instance_manager, :recovery, stage]
    handler_id = {__MODULE__, counter_id, stage}

    :persistent_term.put({:recovery_counter, counter_id, stage}, 0)

    :telemetry.attach(
      handler_id,
      event,
      &__MODULE__.increment_recovery_counter/4,
      {counter_id, stage}
    )

    :ok
  end

  def increment_recovery_counter(_event, _measurements, _metadata, {id, stage_name}) do
    key = {:recovery_counter, id, stage_name}
    current = :persistent_term.get(key, 0)
    :persistent_term.put(key, current + 1)
    :ok
  end

  def read_recovery_counter(counter_id, stage) do
    :persistent_term.get({:recovery_counter, counter_id, stage}, 0)
  end

  def clear_recovery_counter(counter_id, stage) do
    :persistent_term.erase({:recovery_counter, counter_id, stage})
    :telemetry.detach({__MODULE__, counter_id, stage})
    :ok
  end

  def bedrock_key_count(prefix) do
    prefix |> all_keys_for_prefix() |> length()
  end

  def repo_put(key, value), do: JidoCluster.Test.RealBedrockClusterCase.repo_put(key, value)
  def repo_get(key), do: JidoCluster.Test.RealBedrockClusterCase.repo_get(key)

  def manager_tree_snapshot(manager) do
    cluster_sup = JidoCluster.InstanceManager.supervisor_name(manager)
    local_sup = Jido.Agent.InstanceManager.supervisor_name(manager)
    local_registry = Jido.Agent.InstanceManager.registry_name(manager)
    local_dynamic = Jido.Agent.InstanceManager.dynamic_supervisor_name(manager)

    %{
      cluster_supervisor: snapshot_named_process(cluster_sup),
      local_manager_supervisor: snapshot_named_process(local_sup),
      local_registry: snapshot_named_process(local_registry),
      local_dynamic_supervisor: snapshot_named_process(local_dynamic)
    }
  end

  defp snapshot_named_process(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        %{
          name: name,
          pid: pid,
          alive?: Process.alive?(pid),
          children: safe_children(pid)
        }

      _ ->
        %{name: name, pid: nil, alive?: false}
    end
  end

  defp safe_children(pid) do
    Supervisor.which_children(pid)
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp manager_tree_ready?(%{
         cluster_supervisor: %{alive?: true},
         local_manager_supervisor: %{alive?: true},
         local_registry: %{alive?: true},
         local_dynamic_supervisor: %{alive?: true}
       }),
       do: true

  defp manager_tree_ready?(other),
    do: flunk("manager tree not ready: #{inspect(other, pretty: true, limit: :infinity)}")

  defp assert_app_started(:ok), do: :ok
  defp assert_app_started({:ok, _apps}), do: :ok
  defp assert_app_started(other), do: raise("Failed to start app on cluster node: #{inspect(other)}")
end
