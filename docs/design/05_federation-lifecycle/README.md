# S5 — Federation through movement and restart

Status: implemented and verified; review pending approval. All S5 examples and
the static cumulative scenario pass the package checks. See the
[final evidence and limits](plan.md#static-cumulative-proof-and-final-failure-audit).

Depends on: S4, using the S2–S3 lifecycle.

Scope: coordinate detach, source retirement, target readiness, and Ref reattachment
within placement operations. Reconstruct declared bindings after bridge restart.
Expose event gaps, drops, and uncertain cleanup. Retain shared transport while
other deployments use it.

Proof: a moved subscriber receives subsequent events at its new location; stale
location requests cannot attach it again at the source. Bridge failure does not
change host authority. Restart reconstructs bindings without claiming replay of
lost events. Stop preserves unrelated bindings and shared transport.

Living examples: subscription follows placement; bridge interruption and restart.

Detailed decisions: binding revisions, persisted runtime subscriptions, readiness
during degradation, and movement-gap reporting. Durable event delivery is deferred.

The first increment permits exact mirror generation replacement after confirmed
cleanup. A bridge crash can close its export tasks before replacement. A new
mirror can attach to the same Agent; stale requests cannot close the new mirror.
Journaled binding records now precede initial setup and stop. Confirmed activation
cleanup permits reconstruction with an increased binding revision. Real Bedrock
and Mnesia tests retain Agent state and logical binding identity through restart.
Managed drains now journal source retirement and target attachment. Peer tests
cover return to an earlier host and lost write replies. The first living example
uses real Bedrock and shared Mnesia Agent storage. Explicit bridge repair now
retains the current Agent and claims. Shared cleanup and uncertain attachment
examples now pass. The static cumulative proof passes in managed and attached
modes, including delayed target visibility and independent progress during source
uncertainty. Repeated repair after abrupt mirror loss retains uncertainty. See the
[implementation evidence](plan.md#journaled-subscriber-movement) for the tested scope.

## Planning in this folder

Read the [implementation plan](plan.md) for ordered changes, contracts, failure
handling, tests, and completion criteria. Record decisions and evidence as work
progresses. The plan is proposed; passing proof gates are required for completion.

See the [architecture](../00_architecture/README.md) and
[delivery plan](../00_architecture/delivery-plan.md) for shared contracts.

The plan includes [cross-slice refinements](plan.md#cross-slice-refinements) from
the holistic review. Shared requirements live in the
[lifecycle contracts](../00_architecture/lifecycle-contracts.md).
