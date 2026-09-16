defmodule JidoCluster.Test.Bedrock do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.Eventually
  alias Bedrock.ControlPlane.Distributor.Placeholder
  alias Bedrock.ObjectStorage
  alias Bedrock.ObjectStorage.LocalFilesystem

  defmodule Cluster do
    @moduledoc false
    use Bedrock.Cluster, otp_app: :bedrock, name: "jido_cluster_journal_contract"
  end

  defmodule Repo do
    @moduledoc false
    use Bedrock.Repo, cluster: Cluster
  end

  defmodule Owner do
    @moduledoc false
    use Supervisor
    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    def init(_), do: Supervisor.init([Cluster.child_spec([])], strategy: :one_for_one)
  end

  def start(directory) do
    backend = ObjectStorage.backend(LocalFilesystem, root: Path.join(directory, "objects"))

    config = [
      capabilities: [:coordination, :log, :materializer],
      path_to_descriptor: Path.join(directory, "bedrock.cluster"),
      object_storage: backend,
      coordinator: [path: Path.join(directory, "coordinator"), persistent: true],
      worker: [path: Path.join(directory, "workers"), object_storage: backend],
      durability_mode: :relaxed,
      durability: [desired_replication_factor: 1, desired_logs: 1]
    ]

    Application.put_env(:bedrock, Cluster, config)
    Application.put_env(:bedrock, ObjectStorage, backend: backend)
    start_ready()
  end

  def restart do
    :ok = stop()
    start_ready()
  end

  def stop do
    owner = Process.whereis(Owner)
    placeholder = Process.whereis(Cluster.otp_name_for_worker(Placeholder.worker_id()))

    if owner do
      monitor = Process.monitor(owner)
      assert :ok = DynamicSupervisor.terminate_child(JidoCluster.Test.Supervisor, owner)
      assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 10_000
    end

    if placeholder do
      monitor = Process.monitor(placeholder)

      # The cluster owner can retire this exact placeholder between observation
      # and stop. Its monitor still confirms exit; other stop failures must fail.
      try do
        GenServer.stop(placeholder, :shutdown, 10_000)
      catch
        :exit, {:noproc, {GenServer, :stop, _}} -> :ok
      end

      assert_receive {:DOWN, ^monitor, :process, ^placeholder, _}, 10_000
    end

    :ok
  end

  defp start_ready do
    assert {:ok, owner} = DynamicSupervisor.start_child(JidoCluster.Test.Supervisor, {Owner, []})
    # Only a real transaction establishes readiness. Polls have a bounded
    # transaction deadline and cannot serve as proof on their own.
    eventually(&ready?/0, timeout: 30_000)
    {:ok, owner}
  end

  defp ready? do
    Repo.transact(
      fn ->
        Repo.get("jido-cluster/readiness")
        :ok
      end,
      timeout_in_ms: 500,
      retry_limit: 0
    ) == :ok
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end
