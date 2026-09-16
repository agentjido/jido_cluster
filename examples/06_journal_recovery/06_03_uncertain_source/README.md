# 06_03 Uncertain source

Retain source and target claims when a live source disconnects during a recorded drain.

## Read the code

Read [the topology and service](topology.ex), then the [shared Worker](../support/worker.ex),
and the [test](../../../test/examples/06_journal_recovery/06_03_uncertain_source/uncertain_source_test.exs).
Setup uses the [journal example fixture](../../../test/examples/support/journal_recovery_case.ex),
[peer fixture](../../../test/support/cluster_case.ex), and
[real Bedrock fixture](../../../test/support/bedrock.ex).
The [reply adapter](../../../test/examples/support/journal_reply_loss.ex) changes only a test reply or holds it after the real write.

## Run

```sh
mise exec -- mix test test/examples/06_journal_recovery/06_03_uncertain_source --only example --seed 0
```

## Expected result

The fixture holds the reply after Bedrock commits drain admission, then isolates the source from the other peers. It confirms that the source Agent is alive before releasing the reply. Drain and service recovery remain uncertain. Both claims stay charged and no Agent starts on the spare target. After explicit reconnection and reconciliation, the original drain completes and count 1 is restored on the target.

## Boundaries and cleanup

The test uses different peer cookies to prevent automatic reconnection while it checks uncertainty. The source VM stays alive. Cookies are restored before checked cleanup. This tests a symmetric connected-node partition in a controlled fixture. It does not supply a lease, protected-write fencing, or authority to replace an unreachable writer.

Bedrock runs on the control peer with local filesystem storage and relaxed
single-node durability. Agent state uses a shared Mnesia table. Both adapters
are actual implementations. No hosted credentials are needed. A missing backend
is a failure, not a skipped test or memory fallback. The tests check Agent cleanup,
stop the Repo, monitor peer exits, and remove the owned filesystem directory.

Previous: [Unknown write reply](../06_02_unknown_write/README.md) | Next: [Adapter choice](../06_04_adapter_choice/README.md). Return to [06 Journal recovery](../README.md).
