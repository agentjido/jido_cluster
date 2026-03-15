# Acceptance

Acceptance artifacts capture the higher-level recovery stories that sit above
the unit and contract tests: real Bedrock-backed handoff, stale-owner release,
owner-loss failover, restart recovery, and region failover.

## Intent

This subject covers the real Bedrock distributed acceptance helper, the
Bedrock-backed singleton durability tests, the region failover recovery test,
and the Fly multi-region guide.

```spec-meta
id: jido_cluster.acceptance
kind: acceptance
status: active
summary: Bedrock-backed and multi-region acceptance stories for clustered singleton recovery.
surface:
  - guides/fly-multi-region-failover-demo.md
  - test/support/real_bedrock_cluster_case.ex
  - test/jido_cluster/distributed/bedrock_acceptance_test.exs
  - test/jido_cluster/distributed/region_failover_recovery_test.exs
```

## Requirements

```spec-requirements
- id: jido_cluster.acceptance.fly_failover_guide
  statement: The Fly multi-region guide shall document a concrete multi-region drill for one logical Jido.Cluster.InstanceManager with shared storage and DNS-based discovery.
  priority: must
  stability: evolving

- id: jido_cluster.acceptance.multi_region_operational_shape
  statement: The multi-region guide shall describe recovery in terms of continued keyed availability, owner continuity, cluster continuity, and migration plus recovery telemetry.
  priority: must
  stability: evolving

- id: jido_cluster.acceptance.bedrock_shared_storage_handoff
  statement: A manager using the Bedrock adapter shall be able to hand off a singleton key across connected nodes while preserving state through shared Bedrock storage.
  priority: must
  stability: evolving

- id: jido_cluster.acceptance.bedrock_stale_owner_release
  statement: After a Bedrock-backed handoff completes, the old owner node shall not retain a live local singleton for the migrated key.
  priority: must
  stability: evolving

- id: jido_cluster.acceptance.bedrock_owner_loss_failover
  statement: After a Bedrock-backed handoff, terminating the current owner node shall allow the surviving node to thaw the latest acknowledged singleton state from Bedrock and continue serving the key.
  priority: must
  stability: evolving

- id: jido_cluster.acceptance.bedrock_restart_recovery
  statement: Restarting a node against the same Bedrock-backed storage path shall allow the manager to recover previously acknowledged singleton state.
  priority: must
  stability: evolving

- id: jido_cluster.acceptance.bedrock_keyed_fleet_rebalance
  statement: With Bedrock-backed shared storage, a keyed fleet shall rebalance across connected nodes while preserving deterministic ownership, per-key state, and cluster stats.
  priority: must
  stability: evolving

- id: jido_cluster.acceptance.region_failover_serviceable
  statement: With shared storage, a key shall remain serviceable after its owner node is terminated and recovered on a surviving node, and the recovery path shall emit observable recovery telemetry.
  priority: must
  stability: evolving
```

## Verification

```spec-verification
- kind: guide_file
  target: guides/fly-multi-region-failover-demo.md
  covers:
    - jido_cluster.acceptance.fly_failover_guide
    - jido_cluster.acceptance.multi_region_operational_shape

- kind: test_file
  target: test/jido_cluster/distributed/bedrock_acceptance_test.exs
  covers:
    - jido_cluster.acceptance.bedrock_shared_storage_handoff
    - jido_cluster.acceptance.bedrock_stale_owner_release
    - jido_cluster.acceptance.bedrock_owner_loss_failover
    - jido_cluster.acceptance.bedrock_restart_recovery
    - jido_cluster.acceptance.bedrock_keyed_fleet_rebalance

- kind: test_file
  target: test/jido_cluster/distributed/region_failover_recovery_test.exs
  covers:
    - jido_cluster.acceptance.region_failover_serviceable
```
