# Rebalancer

The rebalancer is the conservative migration loop that keeps keys moving toward
their desired owners without blasting the whole cluster at once.

## Intent

This subject covers the manager-scoped rebalancer, its shared-backend gating,
telemetry behavior, and its use of a deterministic leader plus per-tick limits.

```spec-meta
id: jido_cluster.rebalancer
kind: module
status: active
summary: Conservative rebalancer moves mismatched keys only when the cluster and backend permit it.
surface:
  - lib/jido/cluster/rebalancer.ex
  - lib/jido_cluster/rebalancer.ex
  - lib/jido_cluster/internal/remote.ex
  - test/jido_cluster/distributed/instance_manager_cluster_test.exs
  - test/support/eventually.ex
```

## Requirements

```spec-requirements
- id: jido_cluster.rebalancer.public_trigger_api
  statement: The preferred public rebalancer namespace shall expose trigger and trigger_sync operations for manager-scoped migration ticks.
  priority: must
  stability: stable

- id: jido_cluster.rebalancer.skip_non_shared_backends
  statement: Rebalance attempts shall skip non-shared backends and emit skipped migration telemetry instead of trying to move keys.
  priority: must
  stability: stable

- id: jido_cluster.rebalancer.one_key_per_tick_limit
  statement: Shared-backend rebalancing shall migrate at most max_migrations_per_tick keys during one tick.
  priority: must
  stability: stable

- id: jido_cluster.rebalancer.leader_and_cluster_gate
  statement: Rebalance work shall run only on the deterministic leader while the cluster is considered available for that manager.
  priority: must
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: jido_cluster.rebalancer.ets_skip_with_telemetry
  given:
    - a manager using a local ETS backend and a topology mismatch after a node joins
  when:
    - the leader triggers a rebalance tick
  then:
    - the key stays put and skipped migration telemetry is emitted
  covers:
    - jido_cluster.rebalancer.skip_non_shared_backends

- id: jido_cluster.rebalancer.shared_backend_single_migration
  given:
    - a manager using a shared backend and multiple candidate keys that want to move
  when:
    - the leader triggers one rebalance tick
  then:
    - only one key migrates during that tick
  covers:
    - jido_cluster.rebalancer.one_key_per_tick_limit
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_cluster/distributed/instance_manager_cluster_test.exs
  execute: true
  covers:
    - jido_cluster.rebalancer.public_trigger_api
    - jido_cluster.rebalancer.skip_non_shared_backends
    - jido_cluster.rebalancer.one_key_per_tick_limit
    - jido_cluster.rebalancer.leader_and_cluster_gate
    - jido_cluster.rebalancer.ets_skip_with_telemetry
    - jido_cluster.rebalancer.shared_backend_single_migration
```
