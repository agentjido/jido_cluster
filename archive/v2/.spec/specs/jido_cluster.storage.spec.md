# Storage

Cluster storage adapters provide the persistence contract used by shared-backend
failover, migration, and durable thread reconstruction.

## Intent

This subject covers the public storage namespace, the adapter implementations
for ETS, Mnesia, Bedrock, and Postgres, and the adapter regression tests.

```spec-meta
id: jido_cluster.storage
kind: module
status: active
summary: Cluster storage adapters implement checkpoint and thread persistence across local and shared backends.
surface:
  - lib/jido/cluster/storage.ex
  - lib/jido/cluster/storage/bedrock.ex
  - lib/jido/cluster/storage/ets.ex
  - lib/jido/cluster/storage/mnesia.ex
  - lib/jido/cluster/storage/postgres.ex
  - lib/jido_cluster/storage/bedrock.ex
  - lib/jido_cluster/storage/ets.ex
  - lib/jido_cluster/storage/mnesia.ex
  - lib/jido_cluster/storage/postgres.ex
  - test/jido_cluster/storage/bedrock_adapter_test.exs
  - test/jido_cluster/storage/ets_adapter_test.exs
  - test/jido_cluster/storage/mnesia_adapter_test.exs
  - test/jido_cluster/storage/postgres_adapter_test.exs
```

## Requirements

```spec-requirements
- id: jido_cluster.storage.public_storage_namespace
  statement: The preferred Jido.Cluster.Storage namespace shall expose the clustered adapter surface while delegating behavior to the legacy implementation modules.
  priority: must
  stability: stable

- id: jido_cluster.storage.checkpoint_crud
  statement: Storage adapters shall support checkpoint create, read, and delete operations for clustered agent state.
  priority: must
  stability: stable

- id: jido_cluster.storage.thread_round_trip
  statement: Storage adapters shall append, load, and delete thread data while reconstructing thread revision and ordered entries.
  priority: must
  stability: stable

- id: jido_cluster.storage.expected_rev_conflicts
  statement: Adapters that expose optimistic concurrency shall reject stale expected_rev writes with a conflict result.
  priority: must
  stability: stable

- id: jido_cluster.storage.bedrock_prefixed_entry_ranges
  statement: The Bedrock adapter shall scan thread entry prefixes with a strict upper bound so prefixed entry keys are fully loaded and deleted.
  priority: must
  stability: stable

- id: jido_cluster.storage.getting_started_storage_choices
  statement: The getting-started guide shall describe the intended tradeoff between ETS, Mnesia, Bedrock, and Postgres storage backends.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: jido_cluster.storage.adapter_round_trip
  given:
    - any of the supported storage adapters
  when:
    - checkpoints and threads are written, read back, and deleted
  then:
    - the adapter preserves checkpoint payloads and reconstructed thread state
  covers:
    - jido_cluster.storage.checkpoint_crud
    - jido_cluster.storage.thread_round_trip

- id: jido_cluster.storage.bedrock_shared_prefix_thread_load
  given:
    - a Bedrock-backed thread written under a shared prefix
  when:
    - the thread is loaded or deleted through the adapter
  then:
    - all prefixed entries are included in the operation range
  covers:
    - jido_cluster.storage.bedrock_prefixed_entry_ranges
    - jido_cluster.storage.thread_round_trip
```

## Verification

```spec-verification
- kind: source_file
  target: lib/jido/cluster/storage.ex
  covers:
    - jido_cluster.storage.public_storage_namespace

- kind: guide_file
  target: guides/getting-started.md
  covers:
    - jido_cluster.storage.getting_started_storage_choices

- kind: command
  target: mix test test/jido_cluster/storage/ets_adapter_test.exs test/jido_cluster/storage/mnesia_adapter_test.exs test/jido_cluster/storage/postgres_adapter_test.exs test/jido_cluster/storage/bedrock_adapter_test.exs
  execute: true
  covers:
    - jido_cluster.storage.checkpoint_crud
    - jido_cluster.storage.thread_round_trip
    - jido_cluster.storage.expected_rev_conflicts
    - jido_cluster.storage.bedrock_prefixed_entry_ranges
    - jido_cluster.storage.adapter_round_trip
    - jido_cluster.storage.bedrock_shared_prefix_thread_load
```
