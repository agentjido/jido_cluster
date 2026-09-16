# S4 — Scoped federation on static hosts

Status: static-host implementation and S4 acceptance checks pass. Declarations,
bounded connected transport, exact mirror ownership, required bindings, the
publication/status facade, and all three living examples have runtime evidence.
The [requirement audit](plan.md#living-examples-and-s4-acceptance-audit) maps the
slice requirements to tests. Review remains Pending approval. Movement and
restart reconciliation belong to S5.

Depends on: S1–S3.

Scope: topology channel declarations, host-local mirrors, one selected transport,
interest tracking, Ref subscription bindings, and federation status. Keep topology
lowering pure. Required attachments form an additional deployment-readiness step.
Preserve core's existing local Bus rules.

First delivery mode: opt-in best effort. Preserve Signal identity and payload;
bound queues and payloads; prevent loops and suppress duplicate exports within a
stated window. Publication acknowledges local acceptance and outbound submission,
not remote consumption. Direct Agent calls remain a separate path.

Proof: publish on A, receive on subscribed B, and observe no delivery on uninterested
C. Same channel names in separate namespaces/deployments cannot leak events. Full
queues reject according to the declared local acceptance boundary.

Living example: three-host events with isolation and loop assertions.

Detailed decisions: transport, envelope, interest protocol, queue reservation,
publication receipt, duplicate-cache lifetime, and attachment failure handling.

## Planning in this folder

Read the [implementation plan](plan.md) for ordered changes, contracts, failure
handling, tests, and completion criteria. Record decisions and evidence as work
progresses. The plan is proposed; passing proof gates are required for completion.

See the [architecture](../00_architecture/README.md) and
[delivery plan](../00_architecture/delivery-plan.md) for shared contracts.

The plan includes [cross-slice refinements](plan.md#cross-slice-refinements) from
the holistic review. Shared requirements live in the
[lifecycle contracts](../00_architecture/lifecycle-contracts.md).
