# Jido Cluster design

> Current scope after legacy removal: applications use named `Jido.Cluster`
> instances and `Jido.Cluster.Entity`. The standalone manager, standalone
> Scheduler, offline checkpoint importer, example groups 01–03, and V2 archive
> have been removed. `Deployment` is private runtime code under the named scope.
> Earlier statements and test counts below describe historical checkpoints.


Navigation and review conventions are adapted from core Jido at revision `01863527`.
Code, public module documentation, and executable tests define current behavior.
Design documents describe the target; they do not override runtime evidence.
See [design instructions](AGENTS.md).

The folders follow the planned delivery slices. Start with the architecture,
then plan each slice in its own folder. Current runtime guarantees remain in the
[named deployment guide](../../guides/named-deployments.md); design scope is not implementation evidence.

| Folder | Purpose |
| --- | --- |
| [00 Architecture](00_architecture/README.md) | Vision, OTP instances, host ownership, and persistence defaults |
| [Delivery plan](00_architecture/delivery-plan.md) | Shared code seams, process tree, ordering, and proof process |
| [01_instance-and-deployment](01_instance-and-deployment/README.md) | S1 planning entry point |
| [02_admission-and-drain](02_admission-and-drain/README.md) | S2 planning entry point |
| [03_journal-and-recovery](03_journal-and-recovery/README.md) | S3 planning entry point |
| [04_signal-federation](04_signal-federation/README.md) | S4 planning entry point |
| [05_federation-lifecycle](05_federation-lifecycle/README.md) | S5 planning entry point |
| [06_host-providers](06_host-providers/README.md) | S6 planning entry point |
| [07_entity-capabilities](07_entity-capabilities/README.md) | S7 planning entry point |
| [90 Reference](90_reference/README.md) | Earlier proposals and dated alignment reviews |

## Folder convention

Each slice's `README.md` owns its scope, dependencies, proof gates, and open
planning decisions. Its `plan.md` contains the proposed implementation steps.
Use the [planning template](PLAN_TEMPLATE.md) for future slices. Add supporting protocol or decision documents only
when needed, and link them from that README. Keep evidence and status current.

All seven slices have implementation plans in their folders. S1–S7 have
passing local runtime and example evidence, including real Docker provider
acceptance and bounded entity peer cases. See the
[S7 acceptance record](07_entity-capabilities/plan.md#s7-implementation-and-acceptance). The
architecture contains shared decisions; slice plans must not silently redefine
them. Earlier documents are retained under `90_reference` and are not the current
source of truth where they conflict with the architecture or delivery plan.

Read [implementation state](00_architecture/implementation-state.md) for the
completed local increments and proof limits. Runtime verification does not
imply document approval, publication, or a remote CI result.

## Design source

The main discussion is [issue #19: Distributed Agent systems and dynamic infrastructure](https://github.com/agentjido/jido_cluster/issues/19). It is an idea set, not an accepted API or release plan. [Issue #1: Common usage scenarios](https://github.com/agentjido/jido_cluster/issues/1) supplies application examples. Neither issue proves a runtime guarantee.

## Working rules

- Mark each proposal as proposed until a decision is recorded.
- Keep the implementation review separate from the desired design.
- Link each runtime claim to source code and executable evidence.
- Put each public contract in the package that owns it.
- Record a decision with its reason, alternatives, proof requirements, and affected packages.
- Do not copy Jido core runtime semantics into this package.
- Add living examples only for implemented public contracts. Put incomplete experiments in research examples.
- Update this folder when an accepted design or implementation changes.

These documents do not replace the [current guides](../../guides/README.md) or the [runnable examples](../../examples/README.md).

## Holistic review refinements

The [lifecycle contracts](00_architecture/lifecycle-contracts.md) record the agreed
cross-slice direction and proposed observable requirements. Each slice plan links
its additional work and examples to these requirements. The cumulative system
example provides the cross-subsystem promotion gate. No runtime proof is claimed.

## Build preparation

[Build readiness](00_architecture/build-readiness.md) is the entry point for S1.
The [Hyper source review](90_reference/04_hyper/README.md) records pinned evidence
and the applied lessons. No dependency or runtime code was added by that review.

## Review method

Review each slice with the same questions used in core:

1. What does the implementation do today?
2. What target behavior do we want?
3. What gaps remain?
4. Which decisions are needed before implementation?
5. What evidence demonstrates alignment?

Shared contracts belong in [the architecture](00_architecture/README.md). Detailed
behavior belongs in the owning slice. Keep one canonical statement of each fact
and link to it from other documents.

## Requirement format

Use EARS for required target behavior: a stable `<SEAM>-REQ-<number>` identifier,
a named owner, one observable response, and an explicit trigger or condition when
needed. For example, this syntax illustration is not an approved requirement:

```text
CL-JOURNAL-REQ-001: If a journal write result is indeterminate, then the journal coordinator shall report the operation as uncertain.
```

Map requirements to executable evidence or planned acceptance tests. Keep current
facts and proposed decisions separate. See [the full EARS rules](AGENTS.md).

## Document review status

Review status is separate from implementation progress. Use only `Pending approval`
or `Approved`. A document becomes approved only when the user explicitly names it
as approved. Changed documents return to pending; general positive feedback does
not approve each document. This table does not block already authorized work.

| Document | Status |
| --- | --- |
| [00_architecture/README.md](00_architecture/README.md) | Pending approval |
| [00_architecture/delivery-plan.md](00_architecture/delivery-plan.md) | Pending approval |
| [00_architecture/example-testing.md](00_architecture/example-testing.md) | Pending approval |
| [01_instance-and-deployment/README.md](01_instance-and-deployment/README.md) | Pending approval |
| [01_instance-and-deployment/plan.md](01_instance-and-deployment/plan.md) | Pending approval |
| [02_admission-and-drain/README.md](02_admission-and-drain/README.md) | Pending approval |
| [02_admission-and-drain/plan.md](02_admission-and-drain/plan.md) | Pending approval |
| [03_journal-and-recovery/README.md](03_journal-and-recovery/README.md) | Pending approval |
| [03_journal-and-recovery/plan.md](03_journal-and-recovery/plan.md) | Pending approval |
| [04_signal-federation/README.md](04_signal-federation/README.md) | Pending approval |
| [04_signal-federation/plan.md](04_signal-federation/plan.md) | Pending approval |
| [05_federation-lifecycle/README.md](05_federation-lifecycle/README.md) | Pending approval |
| [05_federation-lifecycle/plan.md](05_federation-lifecycle/plan.md) | Pending approval |
| [06_host-providers/README.md](06_host-providers/README.md) | Pending approval |
| [06_host-providers/plan.md](06_host-providers/plan.md) | Pending approval |
| [07_entity-capabilities/README.md](07_entity-capabilities/README.md) | Pending approval |
| [07_entity-capabilities/plan.md](07_entity-capabilities/plan.md) | Pending approval |
| [90_reference/01_package-purpose/README.md](90_reference/01_package-purpose/README.md) | Pending approval |
| [90_reference/01_package-purpose/alignment.md](90_reference/01_package-purpose/alignment.md) | Pending approval |
| [90_reference/01_package-purpose/design.md](90_reference/01_package-purpose/design.md) | Pending approval |
| [90_reference/01_package-purpose/lessons.md](90_reference/01_package-purpose/lessons.md) | Pending approval |
| [90_reference/01_package-purpose/questions.md](90_reference/01_package-purpose/questions.md) | Pending approval |
| [90_reference/02_top-level-api/README.md](90_reference/02_top-level-api/README.md) | Pending approval |
| [90_reference/02_top-level-api/alignment.md](90_reference/02_top-level-api/alignment.md) | Pending approval |
| [90_reference/02_top-level-api/design.md](90_reference/02_top-level-api/design.md) | Pending approval |
| [90_reference/02_top-level-api/host-intelligence.md](90_reference/02_top-level-api/host-intelligence.md) | Pending approval |
| [90_reference/02_top-level-api/signal-federation.md](90_reference/02_top-level-api/signal-federation.md) | Pending approval |
| [90_reference/03_package-focus/README.md](90_reference/03_package-focus/README.md) | Pending approval |
| [90_reference/README.md](90_reference/README.md) | Pending approval |
| [AGENTS.md](AGENTS.md) | Pending approval |
| [PLAN_TEMPLATE.md](PLAN_TEMPLATE.md) | Pending approval |
| [README.md](README.md) | Pending approval |
| [00_architecture/lifecycle-contracts.md](00_architecture/lifecycle-contracts.md) | Pending approval |
| [00_architecture/build-readiness.md](00_architecture/build-readiness.md) | Pending approval |
| [90_reference/04_hyper/README.md](90_reference/04_hyper/README.md) | Pending approval |
| [00_architecture/implementation-state.md](00_architecture/implementation-state.md) | Pending approval |
