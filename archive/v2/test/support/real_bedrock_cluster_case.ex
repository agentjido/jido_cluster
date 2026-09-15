defmodule JidoCluster.Test.RealBedrockClusterCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Bedrock.Cluster.Descriptor
  alias Bedrock.Cluster.Link
  alias Bedrock.ObjectStorage
  alias Bedrock.ObjectStorage.LocalFilesystem
  alias Bedrock.Repo

  defmodule TestCluster do
    @moduledoc false
    use Bedrock.Cluster, otp_app: :bedrock, name: "jido_cluster_real_bedrock_acceptance"
  end

  defmodule TestRepo do
    @moduledoc false
    use Repo, cluster: TestCluster
  end

  using do
    quote do
      import JidoCluster.Test.RealBedrockClusterCase

      alias JidoCluster.Test.RealBedrockClusterCase.TestCluster
      alias JidoCluster.Test.RealBedrockClusterCase.TestRepo
    end
  end

  setup _context do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_cluster_real_bedrock_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      stop_local_bedrock_cluster!()
      Application.delete_env(:bedrock, TestCluster)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, bedrock_prefix: "integration/#{System.unique_integer([:positive])}/"}
  end

  def storage_opts(prefix), do: [repo: TestRepo, prefix: prefix]

  def write_descriptor!(tmp_dir, coordinator_nodes) do
    descriptor_path = Path.join(tmp_dir, "bedrock.cluster")
    File.mkdir_p!(Path.dirname(descriptor_path))

    Descriptor.write_to_file!(
      descriptor_path,
      Descriptor.new(TestCluster.name(), Enum.sort(coordinator_nodes))
    )
  end

  def boot_server_node!(cluster, node, tmp_dir) do
    call_remote_boot!(cluster, node, :start_server_cluster_safe, [tmp_dir], 30_000)
  end

  def boot_client_node!(cluster, node, tmp_dir) do
    call_remote_boot!(cluster, node, :start_client_cluster_safe, [tmp_dir], 30_000)
  end

  def stop_remote_node!(cluster, node) do
    ExUnitCluster.call(cluster, node, __MODULE__, :stop_local_bedrock_cluster!, [])
  end

  def start_server_cluster!(tmp_dir) do
    start_cluster!(:server, tmp_dir)
  end

  def start_client_cluster!(tmp_dir) do
    start_cluster!(:client, tmp_dir)
  end

  def ensure_bedrock_started! do
    Application.ensure_all_started(:bedrock)
  end

  def configure_server_cluster!(tmp_dir) do
    Application.put_env(:bedrock, TestCluster, node_config(tmp_dir, :server))
  end

  def configure_client_cluster!(tmp_dir) do
    Application.put_env(:bedrock, TestCluster, node_config(tmp_dir, :client))
  end

  def start_local_supervisor! do
    start_named_supervisor()
  end

  def start_local_supervisor_unnamed! do
    Supervisor.start_link([TestCluster.child_spec([])], strategy: :one_for_one)
  end

  def start_local_supervisor_safe do
    try do
      start_named_supervisor()
    rescue
      error ->
        {:error, %{kind: :error, reason: error, stacktrace: __STACKTRACE__}}
    catch
      kind, reason ->
        {:error, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__}}
    end
  end

  def local_child_spec do
    TestCluster.child_spec([])
  end

  def local_child_start do
    TestCluster.child_spec([]).start
  end

  def wait_for_layout_safe(timeout_ms \\ 20_000) do
    try do
      wait_for_layout!(timeout_ms)
      :ok
    rescue
      error ->
        {:error, %{kind: :error, reason: error, stacktrace: __STACKTRACE__}}
    catch
      kind, reason ->
        {:error, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__}}
    end
  end

  def start_server_cluster_safe(tmp_dir) do
    safe_start_cluster(:server, tmp_dir)
  end

  def start_client_cluster_safe(tmp_dir) do
    safe_start_cluster(:client, tmp_dir)
  end

  def invoke_boot_safe(function, args) do
    try do
      {:ok, apply(__MODULE__, function, args)}
    rescue
      error ->
        {:error, %{kind: :error, reason: error, stacktrace: __STACKTRACE__}}
    catch
      kind, reason ->
        {:error, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__}}
    end
  end

  def stop_local_bedrock_cluster! do
    case Process.whereis(outer_supervisor_name()) do
      pid when is_pid(pid) ->
        try do
          Supervisor.stop(pid, :normal, 30_000)
        catch
          :exit, _reason -> :ok
        end

        wait_until!(
          fn ->
            Enum.all?(
              [:supervisor, :link, :coordinator, :foreman],
              &is_nil(Process.whereis(TestCluster.otp_name(&1)))
            )
          end,
          10_000
        )

      _ ->
        :ok
    end

    Application.delete_env(:bedrock, TestCluster)
    :ok
  end

  def all_keys_for_prefix(prefix) do
    TestRepo.transact(fn ->
      TestRepo.get_range({prefix, Bedrock.Key.strinc(prefix)}) |> Enum.to_list()
    end)
  end

  def repo_put(key, value) do
    TestRepo.transact(fn -> TestRepo.put(key, value) end, retry_limit: 5)
  end

  def repo_get(key) do
    TestRepo.transact(fn -> {:ok, TestRepo.get(key)} end, retry_limit: 5)
  end

  def debug_snapshot do
    %{
      link: current_link_state(),
      coordinator: current_coordinator_state(),
      director: current_director_state(),
      layout_via_cluster: current_layout_via_cluster(),
      layout_via_link: current_layout_via_link()
    }
  end

  def wait_for_layout!(timeout_ms \\ 20_000) do
    wait_until!(
      fn ->
        layout_ready_via_cluster?() and layout_ready_via_link?()
      end,
      timeout_ms
    )
  end

  defp start_cluster!(role, tmp_dir) do
    assert_app_started(Application.ensure_all_started(:bedrock))

    stop_local_bedrock_cluster!()
    Application.put_env(:bedrock, TestCluster, node_config(tmp_dir, role))

    {:ok, _supervisor} =
      Supervisor.start_link(
        [TestCluster.child_spec([])],
        strategy: :one_for_one,
        name: TestCluster.otp_name(:supervisor)
      )

    wait_for_layout!(if(role == :server, do: 20_000, else: 10_000))
    :ok
  end

  defp node_config(tmp_dir, :server) do
    object_storage =
      ObjectStorage.backend(
        LocalFilesystem,
        root: Path.join([tmp_dir, "coordinator", "object_storage"])
      )

    [
      capabilities: [:coordination, :log, :materializer],
      path_to_descriptor: Path.join(tmp_dir, "bedrock.cluster"),
      object_storage: object_storage,
      trace: [:recovery, :storage],
      coordinator: [path: Path.join(tmp_dir, "coordinator"), persistent: true],
      worker: [path: Path.join(tmp_dir, "workers")],
      durability_mode: :relaxed,
      durability: [desired_replication_factor: 1, desired_logs: 1]
    ]
  end

  defp node_config(tmp_dir, :client) do
    [
      capabilities: [],
      path_to_descriptor: Path.join(tmp_dir, "bedrock.cluster"),
      worker: [path: Path.join(tmp_dir, "workers")],
      durability_mode: :relaxed
    ]
  end

  defp layout_ready?(%{
         logs: logs,
         services: services,
         proxies: proxies,
         resolvers: resolvers,
         shard_layout: shard_layout,
         metadata_materializer: metadata_materializer,
         shard_materializers: shard_materializers
       }) do
    populated_map?(logs) and
      populated_map?(services) and
      populated_list?(proxies) and
      populated_list?(resolvers) and
      populated_map?(shard_layout) and
      is_pid(metadata_materializer) and
      populated_map?(shard_materializers) and
      shard_materializers_cover_layout?(shard_layout, shard_materializers)
  end

  defp layout_ready?(_), do: false

  defp layout_ready_via_cluster? do
    case TestCluster.fetch_transaction_system_layout() do
      {:ok, tsl} -> layout_ready?(tsl)
      _ -> false
    end
  end

  defp layout_ready_via_link? do
    with {:ok, link} <- TestCluster.fetch_link(),
         {:ok, tsl} <- Link.fetch_transaction_system_layout(link) do
      layout_ready?(tsl)
    else
      _ -> seed_link_layout_from_coordinator()
    end
  end

  defp seed_link_layout_from_coordinator do
    with {:ok, link} <- TestCluster.fetch_link(),
         {:ok, tsl} <- TestCluster.fetch_transaction_system_layout(),
         true <- layout_ready?(tsl) do
      send(link, {:tsl_updated, tsl})
      true
    else
      _ -> false
    end
  end

  defp shard_materializers_cover_layout?(shard_layout, shard_materializers) do
    shard_layout
    |> Map.values()
    |> Enum.map(fn {tag, _start_key} -> tag end)
    |> Enum.uniq()
    |> Enum.all?(&match?(pid when is_pid(pid), Map.get(shard_materializers, &1)))
  end

  defp populated_map?(value), do: is_map(value) and map_size(value) > 0
  defp populated_list?(value), do: is_list(value) and value != []

  defp wait_until!(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise ExUnit.AssertionError, message: "condition was not met before timeout"
      else
        Process.sleep(100)
        do_wait_until(fun, deadline)
      end
    end
  end

  defp assert_app_started(:ok), do: :ok
  defp assert_app_started({:ok, _apps}), do: :ok
  defp assert_app_started({:error, {:already_started, _pid}}), do: :ok

  defp call_remote_boot!(cluster, node, function, args, timeout_ms) do
    result = ExUnitCluster.call(cluster, node, __MODULE__, :invoke_boot_safe, [function, args], timeout_ms)

    debug_snapshot =
      case ExUnitCluster.call(cluster, node, __MODULE__, :invoke_boot_safe, [:debug_snapshot, []], timeout_ms) do
        {:ok, snapshot} -> snapshot
        other -> {:debug_snapshot_unavailable, other}
      end

    case result do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, %{kind: kind, reason: reason, stacktrace: stacktrace}}} ->
        raise """
        failed to boot real Bedrock on #{inspect(node)}
        kind: #{inspect(kind)}
        reason: #{inspect(reason)}
        debug_snapshot: #{inspect(debug_snapshot, pretty: true, limit: :infinity)}
        stacktrace: #{Exception.format_stacktrace(stacktrace)}
        """

      {:ok, other} ->
        raise """
        failed to boot real Bedrock on #{inspect(node)}
        unexpected boot result: #{inspect(other, pretty: true, limit: :infinity)}
        debug_snapshot: #{inspect(debug_snapshot, pretty: true, limit: :infinity)}
        """

      {:error, %{kind: kind, reason: reason, stacktrace: stacktrace}} ->
        raise """
        failed to boot real Bedrock on #{inspect(node)}
        kind: #{inspect(kind)}
        reason: #{inspect(reason)}
        debug_snapshot: #{inspect(debug_snapshot, pretty: true, limit: :infinity)}
        stacktrace: #{Exception.format_stacktrace(stacktrace)}
        """

      {:error, details} ->
        raise """
        failed to boot real Bedrock on #{inspect(node)}
        details: #{inspect(details, pretty: true, limit: :infinity)}
        debug_snapshot: #{inspect(debug_snapshot, pretty: true, limit: :infinity)}
        """

      other ->
        raise """
        failed to boot real Bedrock on #{inspect(node)}
        unexpected result: #{inspect(other, pretty: true, limit: :infinity)}
        debug_snapshot: #{inspect(debug_snapshot, pretty: true, limit: :infinity)}
        """
    end
  end

  defp safe_start_cluster(role, tmp_dir) do
    try do
      with {:app_started, app_result} <- {:app_started, Application.ensure_all_started(:bedrock)},
           :ok <- normalize_app_start(app_result),
           {:stopped_existing, :ok} <- {:stopped_existing, stop_local_bedrock_cluster!()},
           {:put_env, :ok} <- {:put_env, Application.put_env(:bedrock, TestCluster, node_config(tmp_dir, role))},
           {:start_supervisor, {:ok, _supervisor}} <- {:start_supervisor, start_named_supervisor()},
           {:wait_for_layout, :ok} <-
             {:wait_for_layout, wait_for_layout(if(role == :server, do: 20_000, else: 10_000))} do
        :ok
      else
        {step, result} ->
          {:error, %{role: role, step: step, result: result}}

        other ->
          {:error, %{role: role, step: :unknown, result: other}}
      end
    rescue
      error ->
        {:error, %{role: role, step: :exception, kind: :error, reason: error, stacktrace: __STACKTRACE__}}
    catch
      kind, reason ->
        {:error, %{role: role, step: :exception, kind: kind, reason: reason, stacktrace: __STACKTRACE__}}
    end
  end

  defp normalize_app_start(:ok), do: :ok
  defp normalize_app_start({:ok, _apps}), do: :ok
  defp normalize_app_start(other), do: other

  defp outer_supervisor_name do
    TestCluster.otp_name("outer_supervisor")
  end

  defp current_layout_via_cluster do
    case TestCluster.fetch_transaction_system_layout() do
      {:ok, tsl} -> %{ready?: layout_ready?(tsl), tsl: tsl}
      other -> other
    end
  end

  defp current_layout_via_link do
    with {:ok, link} <- TestCluster.fetch_link(),
         {:ok, tsl} <- Link.fetch_transaction_system_layout(link) do
      %{ready?: layout_ready?(tsl), tsl: tsl}
    else
      other -> other
    end
  end

  defp current_link_state do
    case Process.whereis(TestCluster.otp_name(:link)) do
      pid when is_pid(pid) ->
        %{
          pid: pid,
          process_info: Process.info(pid, [:status, :current_function, :message_queue_len]),
          state: safe_sys_get_state(pid)
        }

      _ ->
        :link_unavailable
    end
  end

  defp current_coordinator_state do
    case Process.whereis(TestCluster.otp_name(:coordinator)) do
      pid when is_pid(pid) ->
        %{
          pid: pid,
          process_info: Process.info(pid, [:status, :current_function, :message_queue_len]),
          state: safe_sys_get_state(pid)
        }

      _ ->
        :coordinator_unavailable
    end
  end

  defp current_director_state do
    case current_director_pid() do
      pid when is_pid(pid) ->
        %{
          pid: pid,
          process_info: Process.info(pid, [:status, :current_function, :message_queue_len]),
          state: safe_sys_get_state(pid)
        }

      _ ->
        :director_unavailable
    end
  end

  defp current_director_pid do
    case safe_sys_get_state(Process.whereis(TestCluster.otp_name(:coordinator))) do
      %{director: pid} when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp safe_sys_get_state(pid) when is_pid(pid) do
    :sys.get_state(pid, 1_000)
  catch
    :exit, reason -> {:sys_state_unavailable, reason}
  end

  defp safe_sys_get_state(_), do: :unavailable

  defp start_named_supervisor do
    previous = Process.flag(:trap_exit, true)

    try do
      case Supervisor.start_link(
             [TestCluster.child_spec([])],
             strategy: :one_for_one,
             name: outer_supervisor_name()
           ) do
        {:ok, pid} = result ->
          Process.unlink(pid)
          result

        other ->
          other
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp wait_for_layout(timeout_ms) do
    wait_for_layout!(timeout_ms)
    :ok
  end
end
