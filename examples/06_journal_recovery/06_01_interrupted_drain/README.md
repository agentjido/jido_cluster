# 06_01 Interrupted drain

Resume a partially recorded drain after the coordinator process dies.

## Read the code

Read [the topology and service](topology.ex), then the [shared Worker](../support/worker.ex),
and the [test](../../../test/examples/06_journal_recovery/06_01_interrupted_drain/interrupted_drain_test.exs).
Setup uses the [journal example fixture](../../../test/examples/support/journal_recovery_case.ex),
[peer fixture](../../../test/support/cluster_case.ex), and
[real Bedrock fixture](../../../test/support/bedrock.ex).
The [reply adapter](../../../test/examples/support/journal_reply_loss.ex) holds the first confirmed movement reply.
The [movement barrier](../../../test/support/movement_barrier.ex) controls the observed operation boundary.

## Run

```sh
mise exec -- mix test test/examples/06_journal_recovery/06_01_interrupted_drain --only example --seed 0
```

## Expected result

The test moves two workers. It lets the first movement commit, holds the first movement write reply before the second move can start, and kills the coordinator. Bedrock and the worker cores stay alive. After restart, the same drain request completes. Both stable Refs resolve on the target with counts 1 and 2 and their original commit revisions. The old source Agents have stopped and only two target claims remain.

## Boundaries and cleanup

The movement barrier observes public placement telemetry. The reply wrapper then holds the committed first-move write. It is test support, not an application callback. This proves coordinator-process recovery within the same control runtime. It does not prove control-VM loss, repository loss during a move, or cross-node takeover.

Bedrock runs on the control peer with local filesystem storage and relaxed
single-node durability. Agent state uses a shared Mnesia table. Both adapters
are actual implementations. No hosted credentials are needed. A missing backend
is a failure, not a skipped test or memory fallback. The tests check Agent cleanup,
stop the Repo, monitor peer exits, and remove the owned filesystem directory.

Previous: [Shared capacity](../../05_shared_capacity/README.md) | Next: [Unknown write reply](../06_02_unknown_write/README.md). Return to [06 Journal recovery](../README.md).
