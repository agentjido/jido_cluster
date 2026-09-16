# S7 — Entity capabilities from Fabric

> Current scope after legacy removal: applications use named `Jido.Cluster`
> instances and `Jido.Cluster.Entity`. The standalone manager, standalone
> Scheduler, offline checkpoint importer, example groups 01–03, and V2 archive
> have been removed. `Deployment` is private runtime code under the named scope.
> Earlier statements and test counts below describe historical checkpoints.


Status: implementation and local example acceptance pass for the bounded scope
described in the [S7 evidence record](plan.md#s7-implementation-and-acceptance).
Document review remains pending approval.

Depends on: S1–S6 as the planned delivery sequence; identity work itself primarily
depends on the placement and journal contracts.

Scope: port useful identity validation and candidate-selection code; define domain
key to core Ref mapping and keyed demand within a workload scope. Use one admitted
placement path. Preserve existing persisted identities and keep older manager
compatibility explicit. No mandatory Fabric dependency.

Proof: domain identity survives cooperative movement; keyed and declared demand
cannot exceed a shared budget when configured together. Candidate selection and
actual routing agree through transitions or return explicit uncertainty.

Living example: a device entity routed by domain key through movement and recovery.

Detailed decisions: a singleton core Topology per identity, eight active entities
per scope, version-one domain mapping, and an offline old-checkpoint copy. The
legacy manager stays separate.

Replica synchronization, stronger acknowledgement policies, and protected-write
replacement need later protocol slices. Importing Fabric code proves none of them.

## Planning in this folder

Read the [implementation plan](plan.md) for ordered changes, contracts, failure
handling, tests, and completion criteria. Its final section records the bounded
implementation and passing local evidence. Document review is still pending.

See the [architecture](../00_architecture/README.md) and
[delivery plan](../00_architecture/delivery-plan.md) for shared contracts.

The plan includes [cross-slice refinements](plan.md#cross-slice-refinements) from
the holistic review. Shared requirements live in the
[lifecycle contracts](../00_architecture/lifecycle-contracts.md).
