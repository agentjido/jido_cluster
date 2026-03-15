# Disconnected Islands

Disconnected-island coordination is the Bedrock lease-backed execution mode for
logical singleton keys when the runtimes do not rely on connected-BEAM
membership to decide ownership.

## Intent

This subject covers the internal lease store and the `JidoCluster.InstanceManager`
execution path that acquires, renews, releases, and fails over singleton keys
through Bedrock lease coordination.

```spec-meta
id: jido_cluster.disconnected_islands
kind: module
status: active
summary: Bedrock lease-backed singleton execution across disconnected islands.
surface:
  - lib/jido_cluster/instance_manager.ex
  - lib/jido_cluster/lease_store.ex
  - test/jido_cluster/distributed/disconnected_island_runtime_test.exs
```

## Requirements

```spec-requirements
- id: jido_cluster.disconnected_islands.acquire_single_owner
  statement: With `{:bedrock_lease, ...}` coordination, one island shall acquire one logical owner for a key while other islands are rejected until the lease expires or is released.
  priority: must
  stability: evolving

- id: jido_cluster.disconnected_islands.renew_before_expiry
  statement: Repeated manager-routed operations from the current holder shall renew the active lease before expiry.
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
```

## Verification

```spec-verification
- kind: command
  target: mix test --include real_bedrock test/jido_cluster/distributed/disconnected_island_runtime_test.exs
  execute: true
  covers:
    - jido_cluster.disconnected_islands.acquire_single_owner
    - jido_cluster.disconnected_islands.renew_before_expiry
    - jido_cluster.disconnected_islands.expiry_failover
    - jido_cluster.disconnected_islands.stale_holder_rejected
    - jido_cluster.disconnected_islands.release_and_reacquire
```
