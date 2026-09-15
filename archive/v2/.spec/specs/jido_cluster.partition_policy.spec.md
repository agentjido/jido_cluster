# Partition Policy

Partition-policy handling decides when a connected-BEAM cluster should freeze
key ownership instead of continuing to serve potentially conflicting work.

## Intent

This subject covers the freeze-based quorum policy implemented through the
partition monitor and manager availability checks.

```spec-meta
id: jido_cluster.partition_policy
kind: module
status: active
summary: Freeze policy uses connected-node quorum to gate clustered work under partitions.
surface:
  - lib/jido_cluster/partition_monitor.ex
  - lib/jido_cluster/key_runtime.ex
  - lib/jido_cluster/internal/instance_manager_config.ex
  - test/jido_cluster/distributed/instance_manager_cluster_test.exs
  - test/jido_cluster/distributed/ephemeral_instance_manager_cluster_test.exs
  - test/support/eventually.ex
```

## Requirements

```spec-requirements
- id: jido_cluster.partition_policy.freeze_uses_connected_quorum
  statement: For connected_beam coordination with partition_policy :freeze, cluster availability shall depend on the visible node set satisfying min_quorum_nodes.
  priority: must
  stability: stable

- id: jido_cluster.partition_policy.two_node_split_freezes_both_sides
  statement: A two-node split with quorum requirement 2 shall freeze both sides, reject new clustered work, and stop local ownership.
  priority: must
  stability: stable

- id: jido_cluster.partition_policy.live_transfer_freezes_local_runtimes
  statement: For live-transfer managers, a freeze transition shall stop local key runtimes so primaries and standbys cannot keep serving or later promote inside a quorum-losing partition.
  priority: must
  stability: evolving

- id: jido_cluster.partition_policy.freeze_unfreeze_telemetry
  statement: Freeze and unfreeze transitions shall emit partition telemetry with the manager, visible nodes, quorum requirement, and stopped-key count.
  priority: should
  stability: evolving

- id: jido_cluster.partition_policy.three_node_minority_freezes
  statement: In a three-node split with quorum requirement 2, the minority side shall freeze while the majority side can recover ownership.
  priority: must
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: jido_cluster.partition_policy.two_node_freeze_recover
  given:
    - a two-node cluster running a shared-backend manager with quorum 2
  when:
    - the nodes disconnect and later reconnect
  then:
    - both sides freeze during the split and the logical key can resume after heal
  covers:
    - jido_cluster.partition_policy.two_node_split_freezes_both_sides

- id: jido_cluster.partition_policy.live_transfer_freeze
  given:
    - a two-node live-transfer manager with quorum requirement 2
  when:
    - the nodes disconnect
  then:
    - both sides reject work and remove their local key runtimes until quorum returns
  covers:
    - jido_cluster.partition_policy.live_transfer_freezes_local_runtimes

- id: jido_cluster.partition_policy.three_node_majority_recovery
  given:
    - a three-node cluster running a shared-backend manager with quorum 2
  when:
    - one node becomes isolated from the other two
  then:
    - the isolated minority freezes and the majority can recover the key
  covers:
    - jido_cluster.partition_policy.three_node_minority_freezes
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_cluster/distributed/instance_manager_cluster_test.exs
  execute: true
  covers:
    - jido_cluster.partition_policy.freeze_uses_connected_quorum
    - jido_cluster.partition_policy.two_node_split_freezes_both_sides
    - jido_cluster.partition_policy.three_node_minority_freezes
    - jido_cluster.partition_policy.two_node_freeze_recover
    - jido_cluster.partition_policy.three_node_majority_recovery

- kind: command
  target: mix test test/jido_cluster/distributed/ephemeral_instance_manager_cluster_test.exs
  execute: true
  covers:
    - jido_cluster.partition_policy.live_transfer_freezes_local_runtimes
    - jido_cluster.partition_policy.freeze_unfreeze_telemetry
    - jido_cluster.partition_policy.live_transfer_freeze
```
