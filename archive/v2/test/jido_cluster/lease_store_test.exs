defmodule JidoCluster.LeaseStoreTest do
  use ExUnit.Case, async: false

  alias Jido.Cluster.LeaseBackend
  alias JidoCluster.LeaseStore

  defmodule FakeRepo do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)
    def transact(fun), do: transact(fun, [])

    def transact(fun, _opts) do
      try do
        fun.()
      catch
        {:rollback, reason} -> {:error, reason}
        {_module, :rollback, reason} -> {:error, reason}
      end
    end

    def rollback(reason), do: throw({:rollback, reason})
    def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))

    def put(key, value) do
      Agent.update(__MODULE__, &Map.put(&1, key, value))
      :ok
    end
  end

  setup do
    start_supervised!(FakeRepo)
    FakeRepo.reset()
    :ok
  end

  test "lease store emits telemetry for acquire renew stale rejection and release" do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    events = [
      [:jido_cluster, :lease, :acquire],
      [:jido_cluster, :lease, :renew],
      [:jido_cluster, :lease, :expiry],
      [:jido_cluster, :lease, :stale_rejection],
      [:jido_cluster, :lease, :release]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:lease_telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    manager = :lease_store_test
    key = "lease-store-1"
    holder = :holder_a
    backend = LeaseBackend.new!(repo: FakeRepo, prefix: "lease-store/", ttl_ms: 1_000, renew_interval_ms: 250)

    assert {:ok, _lease} = LeaseStore.acquire_or_renew(manager, key, holder, backend)

    assert_receive {:lease_telemetry, [:jido_cluster, :lease, :acquire], %{count: 1},
                    %{manager: ^manager, key: ^key, holder: ^holder}}

    assert {:ok, _lease} = LeaseStore.acquire_or_renew(manager, key, holder, backend)

    assert_receive {:lease_telemetry, [:jido_cluster, :lease, :renew], %{count: 1},
                    %{manager: ^manager, key: ^key, holder: ^holder}}

    assert {:error, :lease_unavailable} = LeaseStore.acquire_or_renew(manager, key, :holder_b, backend)

    assert_receive {:lease_telemetry, [:jido_cluster, :lease, :stale_rejection], %{count: 1},
                    %{manager: ^manager, key: ^key, holder: :holder_b, reason: :lease_unavailable}}

    assert :ok = LeaseStore.release(manager, key, holder, backend)

    assert_receive {:lease_telemetry, [:jido_cluster, :lease, :release], %{count: 1},
                    %{manager: ^manager, key: ^key, holder: ^holder}}
  end

  test "lease store emits expiry telemetry when an expired holder is replaced" do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    events = [
      [:jido_cluster, :lease, :acquire],
      [:jido_cluster, :lease, :expiry]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:lease_telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    manager = :lease_store_expiry_test
    key = "lease-store-expiry-1"
    backend = LeaseBackend.new!(repo: FakeRepo, prefix: "lease-store-expiry/", ttl_ms: 30, renew_interval_ms: 10)

    assert {:ok, _lease} = LeaseStore.acquire_or_renew(manager, key, :holder_a, backend)
    assert_receive {:lease_telemetry, [:jido_cluster, :lease, :acquire], %{count: 1}, %{holder: :holder_a}}

    Process.sleep(50)

    assert {:ok, _lease} = LeaseStore.acquire_or_renew(manager, key, :holder_b, backend)
    assert_receive {:lease_telemetry, [:jido_cluster, :lease, :expiry], %{count: 1}, %{holder: :holder_a}}
    assert_receive {:lease_telemetry, [:jido_cluster, :lease, :acquire], %{count: 1}, %{holder: :holder_b}}
  end
end
