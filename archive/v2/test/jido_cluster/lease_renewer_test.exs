defmodule JidoCluster.LeaseRenewerTest do
  use ExUnit.Case, async: false

  alias Jido.Cluster.LeaseBackend
  alias JidoCluster.LeaseStore

  defmodule FakeLeaseRepo do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{} end)
    end

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
    start_supervised!(FakeLeaseRepo)
    FakeLeaseRepo.reset()
    assert_app_started(Application.ensure_all_started(:jido))
    assert_app_started(Application.ensure_all_started(:jido_cluster))
    :ok
  end

  test "lease-backed manager renews idle local ownership before ttl expiry" do
    manager = :"lease_renewer_#{System.unique_integer([:positive])}"
    key = "lease-renewer-1"
    prefix = "lease-renewer/#{System.unique_integer([:positive])}/"

    lease_opts = [
      repo: FakeLeaseRepo,
      prefix: prefix,
      ttl_ms: 90,
      renew_interval_ms: 25
    ]

    opts = [
      name: manager,
      agent: JidoCluster.Test.CounterAgent,
      storage: nil,
      rebalance: false,
      coordination_backend: {:bedrock_lease, lease_opts}
    ]

    assert {:ok, _pid} = JidoCluster.InstanceManager.start(opts)

    signal = Jido.Signal.new!("inc", %{}, source: "/test")
    assert {:ok, first} = JidoCluster.InstanceManager.call(manager, key, signal, 1_000)
    assert first.state.count == 1

    backend = LeaseBackend.new!(lease_opts)
    Process.sleep(180)

    holder = Node.self()
    assert {:ok, ^holder} = LeaseStore.current_holder(manager, key, backend)
    assert {:error, :lease_unavailable} = LeaseStore.acquire_or_renew(manager, key, :competing_node, backend)

    assert :ok = JidoCluster.InstanceManager.stop(manager, key)
  end

  defp assert_app_started(:ok), do: :ok
  defp assert_app_started({:ok, apps}) when is_list(apps), do: :ok
end
