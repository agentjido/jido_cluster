# S3 — Journal and restart reconciliation

Status: S3 implementation and required slice tests pass. Review is Pending approval.
Later slices and cumulative system tests remain incomplete.

Depends on: S2.

Scope: durable request bindings, desired revisions, claims, drain intent, and
operation steps. Reconcile journal intent with accepted core placement and live
readiness. Define backend requirements separately from Agent checkpoint storage.
Fail closed for mutations when journal evidence is unavailable.

Proof: kill the coordinator during partial drain; retain accepted moves and pending
claims after restart. Repeated request IDs do not repeat completed work. Journal
failure and source loss never produce false success or unauthorized replacement.

Living examples: [journal recovery](../../../examples/06_journal_recovery/README.md),
including interrupted drain, lost reply, live source partition, and adapter choice.

The journal defaults to `Jido.Persistence.Bedrock` through the existing core
persistence contract. Require an application-owned repository; allow an explicit
adapter override. Do not introduce Cluster-specific Ecto or Bedrock adapters.
Record encoding and isolated scope keys belong to Cluster. Agent persistence is
independent, including in attached mode. No silent fallback on missing Bedrock.

Additional proofs: missing optional dependency/repository fails early; an explicit
alternative adapter works; shared repositories do not mix Agent and journal keys;
indeterminate writes preserve uncertainty. Recovery must work using the actual
minimal adapter contract, without assuming listing or multi-key transactions.

Detailed decisions: journal record/index layout, atomic boundaries, retention, recovery order,
and supported coordinator restart. Automatic cross-node failover is not required.

## Planning in this folder

Read the [implementation plan](plan.md) for ordered changes, contracts, failure
handling, tests, and completion criteria. Record decisions and evidence as work
progresses. The plan is proposed; passing proof gates are required for completion.

See the [architecture](../00_architecture/README.md) and
[delivery plan](../00_architecture/delivery-plan.md) for shared contracts.

The plan includes [cross-slice refinements](plan.md#cross-slice-refinements) from
the holistic review. Shared requirements live in the
[lifecycle contracts](../00_architecture/lifecycle-contracts.md).
