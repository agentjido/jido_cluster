# S2 — Shared admission and host drain

Status: implementation plan proposed; implementation not complete.

Depends on: S1.

Scope: one admission owner per configured capacity scope, common host inventory,
claims across deployments, transition capacity, and drain across managed
topologies. Pool aliases cannot double a host's capacity. Exclude draining hosts
from new placement. Keep claims during uncertain cleanup.

Proof: two concurrent deployments compete for one remaining slot; only one starts.
Stopping one deployment retains the other's Agents. Drain moves both deployments
without exceeding transition capacity and preserves core identity and state.

Living examples: competing admission, shared-host cleanup, and shared-host drain.

Detailed decisions: claim granularity, operation serialization, unmanaged capacity,
drain cancellation, and partial activation cleanup.

## Planning in this folder

Read the [implementation plan](plan.md) for ordered changes, contracts, failure
handling, tests, and completion criteria. Record decisions and evidence as work
progresses. The plan is proposed; passing proof gates are required for completion.

See the [architecture](../00_architecture/README.md) and
[delivery plan](../00_architecture/delivery-plan.md) for shared contracts.

The plan includes [cross-slice refinements](plan.md#cross-slice-refinements) from
the holistic review. Shared requirements live in the
[lifecycle contracts](../00_architecture/lifecycle-contracts.md).
