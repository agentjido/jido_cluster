defmodule JidoCluster.LeaseModelsTest do
  use ExUnit.Case, async: true

  alias Jido.Cluster.{Config, FenceToken, Lease, LeaseBackend, LeaseClaim}

  defmodule FakeRepo do
  end

  test "bedrock lease backend normalizes cadence defaults" do
    assert {:ok, %LeaseBackend{} = backend} =
             LeaseBackend.new(repo: FakeRepo, prefix: "leases/")

    assert backend.repo == FakeRepo
    assert backend.prefix == "leases/"
    assert backend.ttl_ms == 15_000
    assert backend.renew_interval_ms == 5_000
  end

  test "bedrock lease backend rejects renew interval greater than ttl" do
    assert {:error, _reason} =
             LeaseBackend.new(
               repo: FakeRepo,
               prefix: "leases/",
               ttl_ms: 2_000,
               renew_interval_ms: 2_500
             )
  end

  test "config normalizes bedrock lease coordination backend into a typed backend" do
    assert {:ok, %Config{} = config} =
             Config.new(
               name: :agents,
               coordination_backend: {:bedrock_lease, [repo: FakeRepo, prefix: "leases/"]}
             )

    assert {:bedrock_lease, %LeaseBackend{} = backend} = config.coordination_backend
    assert backend.repo == FakeRepo
  end

  test "lease claim preserves claimant cadence contract" do
    assert {:ok, %LeaseClaim{} = claim} =
             LeaseClaim.new(
               manager: :agents,
               key: "conversation-1",
               claimant: "region-ord/node-a",
               requested_at_ms: 1_000,
               ttl_ms: 15_000,
               renew_interval_ms: 5_000
             )

    assert claim.claimant == "region-ord/node-a"
    assert claim.renew_interval_ms < claim.ttl_ms
  end

  test "lease and fence token stay aligned" do
    fence_token =
      FenceToken.new!(
        epoch: 4,
        lease_id: "lease-123",
        holder: "region-iad/node-a",
        issued_at_ms: 10_000
      )

    lease =
      Lease.new!(
        manager: :agents,
        key: "conversation-1",
        holder: "region-iad/node-a",
        lease_id: "lease-123",
        epoch: 4,
        issued_at_ms: 10_000,
        expires_at_ms: 25_000,
        ttl_ms: 15_000,
        renew_interval_ms: 5_000,
        fence_token: fence_token
      )

    refute Lease.expired?(lease, 24_999)
    assert Lease.expired?(lease, 25_000)
  end

  test "lease rejects mismatched fence token" do
    fence_token =
      FenceToken.new!(
        epoch: 1,
        lease_id: "lease-abc",
        holder: "region-ord/node-b",
        issued_at_ms: 10
      )

    assert {:error, _reason} =
             Lease.new(
               manager: :agents,
               key: "conversation-1",
               holder: "region-iad/node-a",
               lease_id: "lease-123",
               epoch: 2,
               issued_at_ms: 10,
               expires_at_ms: 20,
               ttl_ms: 10,
               renew_interval_ms: 5,
               fence_token: fence_token
             )
  end
end
