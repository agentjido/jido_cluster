# Ephemeral Runtime

The connected-BEAM ephemeral runtime keeps one primary and one standby process
for a logical key and uses live transfer plus synchronous replication to move
ownership conservatively.

## Intent

This subject covers the per-key runtime behavior for primary and standby roles,
synchronous standby updates, planned handoff, and crash-driven promotion within
the in-memory two-node mode.

```spec-meta
id: jido_cluster.ephemeral_runtime
kind: runtime
status: active
summary: Primary/standby live-transfer runtime for connected two-node clustered agents.
surface:
  - lib/jido_cluster/key_runtime.ex
  - lib/jido_cluster/rebalancer.ex
  - test/jido_cluster/distributed/ephemeral_instance_manager_cluster_test.exs
  - test/support/eventually.ex
  - test/support/test_agent.ex
```

## Requirements

```spec-requirements
- id: jido_cluster.ephemeral_runtime.primary_and_standby_roles
  statement: A clustered key shall maintain one primary runtime and at most one standby runtime across the connected replica set.
  priority: must
  stability: evolving

- id: jido_cluster.ephemeral_runtime.sync_replication_before_reply
  statement: Acknowledged call and cast operations shall synchronize standby state before the primary reports success.
  priority: must
  stability: evolving

- id: jido_cluster.ephemeral_runtime.planned_handoff_preserves_state
  statement: Planned live transfer shall move primary ownership without resetting the logical agent state.
  priority: must
  stability: evolving

- id: jido_cluster.ephemeral_runtime.failover_promotes_latest_acknowledged_state
  statement: When the primary disappears, the standby shall promote using the latest acknowledged replicated state for the key.
  priority: must
  stability: evolving

- id: jido_cluster.ephemeral_runtime.soft_owner_reconnect_heal
  statement: After a soft-owner split heals, the runtime shall converge back to one primary and one standby without duplicating ownership.
  priority: should
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: jido_cluster.ephemeral_runtime.replica_set_boot
  given:
    - two connected nodes running the same ephemeral clustered manager
  when:
    - a caller gets a keyed agent for the first time
  then:
    - one primary runtime and one standby runtime are created for that key
  covers:
    - jido_cluster.ephemeral_runtime.primary_and_standby_roles

- id: jido_cluster.ephemeral_runtime.sync_call_and_cast
  given:
    - a primary and standby runtime already exist for a key
  when:
    - a caller performs acknowledged call and cast operations
  then:
    - both runtimes reflect the same replicated state before the caller sees success
  covers:
    - jido_cluster.ephemeral_runtime.sync_replication_before_reply

- id: jido_cluster.ephemeral_runtime.planned_handoff
  given:
    - a key whose desired owner changes after a new node joins
  when:
    - the rebalancer performs a planned live transfer
  then:
    - the new primary preserves the prior logical agent state
  covers:
    - jido_cluster.ephemeral_runtime.planned_handoff_preserves_state

- id: jido_cluster.ephemeral_runtime.primary_loss_failover
  given:
    - a replicated key with acknowledged state on the standby
  when:
    - the primary node terminates
  then:
    - the standby promotes and continues from the latest acknowledged state
  covers:
    - jido_cluster.ephemeral_runtime.failover_promotes_latest_acknowledged_state

- id: jido_cluster.ephemeral_runtime.soft_owner_reconnect_heal
  given:
    - a soft-owner split where the standby promoted during temporary isolation
  when:
    - cluster connectivity heals and both runtimes can compare ownership state again
  then:
    - the key converges back to one primary and one standby with a consistent healed ownership view and preserved acknowledged sequence
  covers:
    - jido_cluster.ephemeral_runtime.soft_owner_reconnect_heal
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_cluster/distributed/ephemeral_instance_manager_cluster_test.exs
  execute: true
  covers:
    - jido_cluster.ephemeral_runtime.primary_and_standby_roles
    - jido_cluster.ephemeral_runtime.sync_replication_before_reply
    - jido_cluster.ephemeral_runtime.planned_handoff_preserves_state
    - jido_cluster.ephemeral_runtime.failover_promotes_latest_acknowledged_state
    - jido_cluster.ephemeral_runtime.replica_set_boot
    - jido_cluster.ephemeral_runtime.sync_call_and_cast
    - jido_cluster.ephemeral_runtime.planned_handoff
    - jido_cluster.ephemeral_runtime.primary_loss_failover
    - jido_cluster.ephemeral_runtime.soft_owner_reconnect_heal
```
