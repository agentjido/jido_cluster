# S6 — Acquired host ownership and one provider

Status: implementation and acceptance complete; review pending approval. Provider contracts,
durable host sessions, and service integration pass controlled local and peer
tests. The Docker adapter passes HTTP contract tests and real Engine tests. The controlled
[provider cumulative example](../../../examples/11_system/11_02_provider_lifecycle/README.md)
passes in managed and attached Core modes with real Bedrock and both controlled
and Docker providers. All five provider examples pass with real Docker workers.
The Linux worker image build, five backend cases, nine example cases, and exact
container cleanup pass. See the [S6 acceptance record](plan.md#real-docker-acceptance-and-s6-audit). See the [service evidence](plan.md#controlled-service-integration)
and [adapter limits](plan.md#local-docker-engine-adapter).

Depends on: S1–S5, especially journal-backed resource identity in S3.

Scope: provider request identity, owned versus borrowed resources, host incarnation,
runtime compatibility, acquisition limits, and release after confirmed cleanup.
Select one backend during detailed planning: Docker, Sprites, Fly Machines, or a
defined Kubernetes resource. The initial LitterBox review selects a narrow Docker
adapter without the full sandbox dependency. See the
[source review and contract evidence](plan.md#initial-provider-contract-and-source-review).

Proof: acquisition timeout finds the same resource or reports uncertainty; it does
not create a duplicate. Provider-ready is insufficient until runtime and topology
readiness hold. Coordinator loss retains owned-resource records. Stop releases only
unused owned capacity after Agent and federation cleanup.

Living example: acquire capacity, deploy a topology with a federated channel, run
work, stop, and verify final resource release. Borrowed hosts remain running.

Detailed decisions: backend, resource ownership unit, preparation, credentials,
network connectivity, idempotent inspection/release, and shared-host retention.

## Planning in this folder

Read the [implementation plan](plan.md) for ordered changes, contracts, failure
handling, tests, and completion criteria. Record decisions and evidence as work
progresses. The plan is proposed; passing proof gates are required for completion.

See the [architecture](../00_architecture/README.md) and
[delivery plan](../00_architecture/delivery-plan.md) for shared contracts.

The plan includes [cross-slice refinements](plan.md#cross-slice-refinements) from
the holistic review. Shared requirements live in the
[lifecycle contracts](../00_architecture/lifecycle-contracts.md).
