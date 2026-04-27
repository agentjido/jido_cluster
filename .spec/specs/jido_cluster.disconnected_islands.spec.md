# Disconnected Islands

Disconnected-island coordination is the Bedrock lease-backed execution mode for
logical singleton keys when the runtimes do not rely on connected-BEAM
membership to decide ownership. This is an advanced experimental mode, not the
primary public `jido_cluster` deployment model.

## Intent

This subject covers the internal lease store and the `JidoCluster.InstanceManager`
execution path that acquires, renews, releases, and fails over singleton keys
through Bedrock lease coordination.

The primary `jido_cluster` runtime remains connected-BEAM keyed singleton
routing. Broader multi-cluster routing and identity fabric behavior belong in a
future private `jido_fabric` package.

```spec-meta
id: jido_cluster.disconnected_islands
kind: module
status: experimental
summary: Experimental Bedrock lease-backed singleton execution across disconnected islands.
surface:
  - lib/jido_cluster/instance_manager.ex
  - lib/jido_cluster/lease_renewer.ex
  - lib/jido_cluster/lease_store.ex
  - test/jido_cluster/lease_renewer_test.exs
  - test/jido_cluster/distributed/disconnected_island_runtime_test.exs
```

## Requirements

```spec-requirements
- id: jido_cluster.disconnected_islands.acquire_single_owner
  statement: In the experimental `{:bedrock_lease, ...}` coordination mode, one island shall acquire one logical owner for a key while other islands are rejected until the lease expires or is released.
  priority: must
  stability: evolving

- id: jido_cluster.disconnected_islands.renew_before_expiry
  statement: Repeated manager-routed operations from the current holder shall renew the active lease before expiry.
  priority: must
  stability: evolving

- id: jido_cluster.disconnected_islands.background_renewal
  statement: A live local lease holder shall renew idle local keys in the background before TTL expiry so another claimant cannot take over solely because no manager-routed operation arrived.
  priority: must
  stability: evolving

- id: jido_cluster.disconnected_islands.expiry_failover
  statement: After lease expiry, another island shall be able to acquire the same key, thaw shared durable state, and continue execution.
  priority: must
  stability: evolving

- id: jido_cluster.disconnected_islands.stale_holder_rejected
  statement: After another island acquires a key, the stale previous holder shall reject manager-routed operations and stop any local runtime for that key.
  priority: must
  stability: evolving

- id: jido_cluster.disconnected_islands.release_and_reacquire
  statement: Releasing a lease shall allow another island to reacquire the same key without same-key dual ownership.
  priority: must
  stability: evolving

- id: jido_cluster.disconnected_islands.lease_telemetry
  statement: Lease acquire, renew, release, expiry, stale rejection, and failure paths shall emit lease telemetry events.
  priority: should
  stability: evolving
```

## Verification

```spec-verification
- kind: command
  target: mix test --include real_bedrock test/jido_cluster/distributed/disconnected_island_runtime_test.exs
  execute: true
  covers:
    - jido_cluster.disconnected_islands.acquire_single_owner
    - jido_cluster.disconnected_islands.renew_before_expiry
    - jido_cluster.disconnected_islands.background_renewal
    - jido_cluster.disconnected_islands.expiry_failover
    - jido_cluster.disconnected_islands.stale_holder_rejected
    - jido_cluster.disconnected_islands.release_and_reacquire
    - jido_cluster.disconnected_islands.lease_telemetry

- kind: command
  target: mix test test/jido_cluster/lease_renewer_test.exs
  execute: true
  covers:
    - jido_cluster.disconnected_islands.background_renewal
```
