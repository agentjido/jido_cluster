# Cluster Models

Typed cluster models define the stable data contracts that higher-level runtime
code passes between managers, runtimes, and topology helpers.

## Intent

This subject covers the `Jido.Cluster.*` structs that replaced loose maps for
manager configuration, placement, ownership, runtime summaries, and snapshots.

```spec-meta
id: jido_cluster.cluster_models
kind: module
status: active
summary: Typed structs normalize cluster config, placement, and runtime state exchange.
surface:
  - lib/jido/cluster/config.ex
  - lib/jido/cluster/replication.ex
  - lib/jido/cluster/placement.ex
  - lib/jido/cluster/ownership.ex
  - lib/jido/cluster/runtime_summary.ex
  - lib/jido/cluster/runtime_snapshot.ex
  - lib/jido/cluster/topology/view.ex
  - lib/jido/cluster/key_runtime/state.ex
  - test/jido_cluster/structs_test.exs
```

## Requirements

```spec-requirements
- id: jido_cluster.cluster_models.config_typed_replication
  statement: Cluster manager config shall normalize replication settings into a typed Jido.Cluster.Replication struct with validated policy fields.
  priority: must
  stability: stable

- id: jido_cluster.cluster_models.shared_role_epoch_seq
  statement: Placement, ownership, runtime summary, and runtime snapshot contracts shall use consistent role, epoch, and sequence semantics, where role is per-runtime, epoch orders ownership changes, and sequence orders acknowledged replicated updates.
  priority: must
  stability: stable

- id: jido_cluster.cluster_models.ownership_summary_snapshot_contract
  statement: Ownership, runtime summary, and runtime snapshot structs shall describe the same primary/standby pair and expose enough metadata to compare competing views during handoff, failover, and heal.
  priority: must
  stability: stable

- id: jido_cluster.cluster_models.topology_view_metadata
  statement: Cluster topology views shall carry the visible node set, elected leader, quorum result, and observation timestamp as typed data.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: jido_cluster.cluster_models.typed_round_trip_examples
  given:
    - representative config, placement, ownership, snapshot, and topology inputs
  when:
    - the structs are constructed through their public constructors
  then:
    - the resulting values preserve typed role, epoch, sequence, and quorum metadata
  covers:
    - jido_cluster.cluster_models.config_typed_replication
    - jido_cluster.cluster_models.shared_role_epoch_seq
    - jido_cluster.cluster_models.ownership_summary_snapshot_contract
    - jido_cluster.cluster_models.topology_view_metadata
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_cluster/structs_test.exs
  execute: true
  covers:
    - jido_cluster.cluster_models.config_typed_replication
    - jido_cluster.cluster_models.ownership_summary_snapshot_contract
    - jido_cluster.cluster_models.shared_role_epoch_seq
    - jido_cluster.cluster_models.topology_view_metadata
    - jido_cluster.cluster_models.typed_round_trip_examples
```
