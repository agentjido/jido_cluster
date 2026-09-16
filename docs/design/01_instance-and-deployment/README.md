# S1 — Static topology deployment service

Status: implementation plan proposed; implementation not complete.

Depends on: current connected Scheduler and core Controller.

Scope: `use Jido.Cluster`, generated OTP callbacks, module/application/start-option
configuration, managed and attached Jido modes, static host pools, topology validation, pure plans,
deployment status, stable Ref lookup, and basic operation identity. Preserve the
current root-singleton scope and existing APIs. Reject unsupported topology forms
before activation. Operations can initially be explicitly memory-only.

Proof: deploy and stop one core topology; preserve namespace and identity; report
core readiness accurately; duplicate connected owners start no extra Controller.
A plan starts nothing. A timeout never triggers automatic Signal replay.
Test both ownership modes: managed core startup and shutdown order, attached core
retention after Cluster stop, missing attached instance, conflicting names or
namespaces, and core loss during an operation. Configuration overrides are tested.
Default Bedrock configuration is validated from this slice; memory-only operation
tracking is an interim limitation, not the final journal default.

Living example: plan, deploy, await readiness, call by Ref, inspect, and stop.

Detailed decisions: scope identity, facade signatures, definition identity,
request conflicts, and the minimum compatibility evidence for static hosts.

## Planning in this folder

Read the [implementation plan](plan.md) for ordered changes, contracts, failure
handling, tests, and completion criteria. Record decisions and evidence as work
progresses. The plan is proposed; passing proof gates are required for completion.

See the [architecture](../00_architecture/README.md) and
[delivery plan](../00_architecture/delivery-plan.md) for shared contracts.

The plan includes [cross-slice refinements](plan.md#cross-slice-refinements) from
the holistic review. Shared requirements live in the
[lifecycle contracts](../00_architecture/lifecycle-contracts.md).
