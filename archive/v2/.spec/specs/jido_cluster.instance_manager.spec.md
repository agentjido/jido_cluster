# Instance Manager

The instance manager is the public clustered control plane for keyed agent
lookup, routing, and ownership-aware lifecycle operations.

## Intent

This subject covers manager-routed access through `Jido.Cluster.InstanceManager`
and the high-level distributed scenarios that callers use instead of depending
on raw pids as the stable contract.

```spec-meta
id: jido_cluster.instance_manager
kind: module
status: active
summary: Manager-routed clustered singleton access across connected nodes.
surface:
  - lib/jido/cluster/instance_manager.ex
  - lib/jido_cluster/instance_manager.ex
  - test/jido_cluster/distributed/ephemeral_runtime_scenarios_test.exs
  - test/support/eventually.ex
  - test/support/test_agent.ex
```

## Requirements

```spec-requirements
- id: jido_cluster.instance_manager.manager_routed_singleton
  statement: Clustered agent access shall route by manager and key so the current owner can change without making raw pids the stability boundary.
  priority: must
  stability: stable

- id: jido_cluster.instance_manager.returned_pids_are_observational
  statement: `get` and `lookup` shall return observational pids for the current primary rather than a durable cross-node identity for the logical key.
  priority: must
  stability: stable

- id: jido_cluster.instance_manager.live_transfer_bootstraps_replica_set
  statement: In live-transfer mode, manager-routed get, call, and cast operations shall ensure the primary and standby replica set exists before signaling the logical agent.
  priority: must
  stability: evolving

- id: jido_cluster.instance_manager.owner_queries_reflect_cluster_view
  statement: owner_node and stats shall reflect the current distributed placement and visible primary ownership for the cluster view.
  priority: must
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: jido_cluster.instance_manager.single_node_lifecycle
  given:
    - a single connected node running an ephemeral clustered manager
  when:
    - a caller gets, calls, casts, and inspects a keyed agent through the manager
  then:
    - the manager exposes one stable logical singleton lifecycle for that key
  covers:
    - jido_cluster.instance_manager.manager_routed_singleton
    - jido_cluster.instance_manager.returned_pids_are_observational
    - jido_cluster.instance_manager.owner_queries_reflect_cluster_view

- id: jido_cluster.instance_manager.mirrored_access_from_either_node
  given:
    - two connected nodes running the same ephemeral clustered manager
  when:
    - callers access the same key from either node
  then:
    - both callers route through one logical singleton with a synchronized primary and standby
  covers:
    - jido_cluster.instance_manager.manager_routed_singleton
    - jido_cluster.instance_manager.returned_pids_are_observational
    - jido_cluster.instance_manager.live_transfer_bootstraps_replica_set

- id: jido_cluster.instance_manager.join_rebalance_without_state_reset
  given:
    - a clustered manager that starts on one node and later gains a second node
  when:
    - ownership rebalances to the new owner
  then:
    - the logical agent remains available and preserves prior state
  covers:
    - jido_cluster.instance_manager.manager_routed_singleton
    - jido_cluster.instance_manager.owner_queries_reflect_cluster_view

- id: jido_cluster.instance_manager.multi_key_fleet_distribution
  given:
    - two connected nodes and many distinct keys
  when:
    - the keys are accessed through the clustered manager
  then:
    - primary ownership is distributed across both nodes by key
  covers:
    - jido_cluster.instance_manager.owner_queries_reflect_cluster_view
```

## Verification

```spec-verification
- kind: source_file
  target: lib/jido/cluster/instance_manager.ex
  covers:
    - jido_cluster.instance_manager.manager_routed_singleton

- kind: command
  target: mix test test/jido_cluster/distributed/ephemeral_runtime_scenarios_test.exs
  execute: true
  covers:
    - jido_cluster.instance_manager.manager_routed_singleton
    - jido_cluster.instance_manager.returned_pids_are_observational
    - jido_cluster.instance_manager.live_transfer_bootstraps_replica_set
    - jido_cluster.instance_manager.owner_queries_reflect_cluster_view
    - jido_cluster.instance_manager.single_node_lifecycle
    - jido_cluster.instance_manager.mirrored_access_from_either_node
    - jido_cluster.instance_manager.join_rebalance_without_state_reset
    - jido_cluster.instance_manager.multi_key_fleet_distribution
```
