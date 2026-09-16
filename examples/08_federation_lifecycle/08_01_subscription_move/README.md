# 08_01 Subscription move

Move a declared subscriber from a draining host and retain its Ref and committed events.

## What you will learn

- Wait for Agent and required binding readiness after a drain.
- Keep logical binding identity while its location revision increases.
- Reject delayed attachment to a retired source generation.

## Read the code

Read [the Recorder and topology](subscriber.ex), then the
[test](../../../test/examples/08_federation_lifecycle/08_01_subscription_move/subscriber_test.exs).
The [lifecycle fixture](../../../test/examples/support/federation_lifecycle_case.ex)
starts a control node, two workers, a real Bedrock journal, and shared Mnesia
Agent storage. It uses the [peer fixture](../../../test/support/cluster_case.ex)
and [Bedrock fixture](../../../test/support/bedrock.ex).

## Run it

```sh
mise exec -- mix test test/examples/08_federation_lifecycle/08_01_subscription_move --only example --seed 0
```

Expected result: the original Agent records `before`. After the drain, the same
Ref resolves to a new PID on the target, with `before` still in its state. A fresh
publication adds `after`. The logical binding ID stays the same; its revision
increases. The source Agent and old channel components have exited. A delayed
source creation request is rejected. Stop removes the current components and
releases all claims. The fixture checks Core, journal, and peer cleanup.

## Important behavior

Cluster records movement intent before source binding cleanup. It confirms that
cleanup before Core moves the Agent, then records target attachment and readiness.
All channel mirrors in this deployment are replaced during the move. Other
deployments have separate mirrors. The original deployment operation stays
completed; the drain has its own operation record.

## Limits

Delivery is best effort. The test publishes after settled readiness, and does
not promise delivery during the movement gap or replay of memory events. Shared
Agent storage preserves committed state; the journal alone does not do this.
Bedrock runs on one peer with relaxed filesystem durability. This test does not
prove replica failure, bridge repair, or movement from an unreachable source.
It needs no credentials or external service.

Previous: [07_03 Bounded publication](../../07_federation/07_03_bounded_publication/README.md).
Next: [08_02 Bridge restart](../08_02_bridge_restart/README.md).
