# 08_04 Uncertain attachment

Keep target placement and binding completion separate when an attachment journal reply is lost.

## What you will learn

- Observe target Agent readiness before required binding completion.
- Retain both claims until explicit recovery resolves an unknown journal reply.

## Read the code

Read [the Recorder and topology](subscriber.ex), then the
[test](../../../test/examples/08_federation_lifecycle/08_04_uncertain_attachment/uncertain_attachment_test.exs).
The [lifecycle fixture](../../../test/examples/support/federation_lifecycle_case.ex)
uses the [peer fixture](../../../test/support/cluster_case.ex), a
[real Bedrock journal](../../../test/support/bedrock.ex), and shared Mnesia Agent storage.
The [reply-loss fixture](../../../test/examples/support/journal_reply_loss.ex) controls the journal failure.

## Run it

```sh
mise exec -- mix test test/examples/08_federation_lifecycle/08_04_uncertain_attachment --only example --seed 0
```

Expected result: the test delivers `before`, then drains the subscriber host. A test adapter lets
real Bedrock commit the target attachment intent and discards its reply. Core has
a ready target Agent with the committed event, but no target mirror exists. The
drain remains incomplete, publication is blocked, and both claims remain held.
Explicit recovery confirms cleanup and replaces the activation. The same Ref
retains `before` and receives `after`. The original drain request completes.
The test checks old, intermediate, and recovered Agent exits and final cleanup.

## Important behavior and limits

The fault wrapper changes only the adapter reply after a real Bedrock commit.
It does not simulate target Agent execution or replace Bedrock storage. This
example tests an unknown journal reply before mirror creation; it does not cover
every remote attachment failure. Recovery uses full activation cleanup, so the
target PID changes. Separate Mnesia Agent storage preserves committed state.
Bedrock has one peer and relaxed durability. No durable event replay is promised.
No credentials or external service are needed. The fixture checks Core, journal,
and peer cleanup after deployment cleanup.

Previous: [08_03](../08_03_shared_cleanup/README.md) |
Next: [11_01 Deployment lifecycle](../../11_system/11_01_deployment_lifecycle/README.md).
