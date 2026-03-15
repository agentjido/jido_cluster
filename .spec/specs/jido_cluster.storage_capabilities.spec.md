# Storage Capabilities

Storage capability policy tells the clustered runtime whether a backend is safe
for cross-node migration and failover behavior.

## Intent

This subject covers the backend classification helpers used by the rebalancer
and manager configuration to distinguish local-only storage from shared storage.

```spec-meta
id: jido_cluster.storage_capabilities
kind: module
status: active
summary: Storage capability helpers classify which backends support shared-node migration semantics.
surface:
  - lib/jido/cluster/storage_capabilities.ex
  - lib/jido_cluster/storage_capabilities.ex
  - test/jido_cluster/storage/storage_capabilities_test.exs
```

## Requirements

```spec-requirements
- id: jido_cluster.storage_capabilities.ets_is_not_shared
  statement: ETS-backed storage shall be classified as non-shared so automatic migrations do not assume cross-node durability.
  priority: must
  stability: stable

- id: jido_cluster.storage_capabilities.shared_backends_are_enabled
  statement: Mnesia, Bedrock, and Postgres cluster adapters shall be classified as shared backends for migration and failover behavior.
  priority: must
  stability: stable

- id: jido_cluster.storage_capabilities.unknown_adapter_shared_opt
  statement: Unknown adapters shall fall back to opts[:shared] when determining whether the backend is migration-safe.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_cluster/storage/storage_capabilities_test.exs
  execute: true
  covers:
    - jido_cluster.storage_capabilities.ets_is_not_shared
    - jido_cluster.storage_capabilities.shared_backends_are_enabled
    - jido_cluster.storage_capabilities.unknown_adapter_shared_opt
```
