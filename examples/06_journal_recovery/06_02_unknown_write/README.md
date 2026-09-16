# 06_02 Unknown write reply

Recover the original request when a real Bedrock write commits but its reply is lost.

## Read the code

Read [the topology and service](topology.ex), then the [shared Worker](../support/worker.ex),
and the [test](../../../test/examples/06_journal_recovery/06_02_unknown_write/unknown_write_test.exs).
Setup uses the [journal example fixture](../../../test/examples/support/journal_recovery_case.ex),
[peer fixture](../../../test/support/cluster_case.ex), and
[real Bedrock fixture](../../../test/support/bedrock.ex).
The [reply adapter](../../../test/examples/support/journal_reply_loss.ex) changes only a test reply or holds it after the real write.

## Run

```sh
mise exec -- mix test test/examples/06_journal_recovery/06_02_unknown_write --only example --seed 0
```

## Expected result

A test adapter delegates the write to Bedrock, then returns a timeout. A direct journal read finds the accepted request, while no Agent has started. The service reports `:journal_unavailable`. Restart and explicit reconciliation restore the same operation ID. A duplicate request returns that ID and preserves the ready Agent PID.

## Boundaries and cleanup

Only the reply is changed. Storage is the real backend. This is a committed-write timeout, not an exception before a write. The example does not replay business Signals or prove distributed exactly-once delivery.

Bedrock runs on the control peer with local filesystem storage and relaxed
single-node durability. Agent state uses a shared Mnesia table. Both adapters
are actual implementations. No hosted credentials are needed. A missing backend
is a failure, not a skipped test or memory fallback. The tests check Agent cleanup,
stop the Repo, monitor peer exits, and remove the owned filesystem directory.

Previous: [Interrupted drain](../06_01_interrupted_drain/README.md) | Next: [Uncertain source](../06_03_uncertain_source/README.md). Return to [06 Journal recovery](../README.md).
