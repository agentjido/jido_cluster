# 06_04 Adapter choice

Choose journal storage separately from Agent persistence and preserve stopped intent.

## Read the code

Read [the topology and service](topology.ex), then the [shared Worker](../support/worker.ex),
and the [test](../../../test/examples/06_journal_recovery/06_04_adapter_choice/adapter_choice_test.exs).
Setup uses the [journal example fixture](../../../test/examples/support/journal_recovery_case.ex),
[peer fixture](../../../test/support/cluster_case.ex), and
[real Bedrock fixture](../../../test/support/bedrock.ex).

## Run

```sh
mise exec -- mix test test/examples/06_journal_recovery/06_04_adapter_choice --only example --seed 0
```

## Expected result

The same lifecycle runs with real Bedrock and explicit Mnesia journals. Agent state uses Mnesia. A worker commits count 1, the service restarts, and explicit reconciliation restores its Ref and state on a new PID. Stop removes the Agent. A further restart keeps stopped intent, empty claims, and the original stop receipt. Missing default Repo configuration fails before startup.

## Boundaries and cleanup

An attached core keeps its own persistence settings. The journal does not store Agent checkpoints. The Mnesia case shares one table through separate key spaces. The Bedrock case uses a separate journal backend. These fixtures do not prove storage-service failover or machine-loss durability.

Bedrock runs on the control peer with local filesystem storage and relaxed
single-node durability. Agent state uses a shared Mnesia table. Both adapters
are actual implementations. No hosted credentials are needed. A missing backend
is a failure, not a skipped test or memory fallback. The tests check Agent cleanup,
stop the Repo, monitor peer exits, and remove the owned filesystem directory.

Previous: [Uncertain source](../06_03_uncertain_source/README.md). Return to [06 Journal recovery](../README.md).
