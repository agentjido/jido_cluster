# What the first examples prove

Status: source review and proposed next proof. This document does not accept a new runtime API.

The first examples prove that cluster code can use the core V3 contracts. They do not yet prove a maintained placement service. Passing tests establish the tested behavior; they do not establish a separate package purpose.

## Core already supplies the mechanisms

Core owns exact-node activation, Ref identity, checkpoint restore, readiness, and cooperative movement. Its [placement-policy example](../../../../jido/examples/07_topology/07_08_placement_policy/README.md) also shows a control Agent and Plugin that submit placement requests. A cluster package must add a reusable policy and its lifecycle, rather than another wrapper around those requests.

| Existing lesson | Core contribution | Current cluster contribution | Missing package proof |
| --- | --- | --- | --- |
| Eligible node | Activate the declared Agents on exact nodes | Filter an application-supplied inventory and hash the eligible nodes | Obtain a current inventory and maintain the selected placement |
| Label extension | Lower and validate extension output | Store label requirements in ordinary Topology metadata | Consume those requirements through a public cluster runtime without test-selected nodes |
| Stateful move | Stop the old activation, restore the checkpoint, retain the Ref, and report readiness | Select the target node | Own a bounded move operation, reconcile failures, and report its result |
| Host recovery | Activate a replacement with the same identity and checkpoint | Select a surviving compatible node | Detect loss and coordinate replacement without the test replacing the Controller |
| Bus locality | Reject a remote placement that uses a local Bus | Check the same constraint before the core request | Integrate compatibility checks with admission and scheduling |
| Keyed counter | Execute Signals and persist committed state | Find participating managers, route a key, serialize connected-node work, and request restore after owner loss | Map the key contract to core Refs and decide how it relates to declared Topologies |

The [Topology fixture](../../../test/examples/support/topology_case.ex) supplies `repair: :manual`. Its [definition builder](../../../test/examples/support/definition.ex) writes selected nodes into the definition before activation. The [recovery test](../../../test/examples/02_topologies/02_04_host_recovery/host_recovery_test.exs) stops and replaces the Controller itself. That test code is acting as the missing coordinator.

The [selector](../../../lib/jido/cluster/placement.ex) is a useful pure function. It does not discover hosts, reserve capacity, monitor loss, or reconcile an operation. The [extension](../../../lib/jido/cluster/topology/extension.ex) is useful authoring syntax. Static lowering does not supply any of those runtime services.

## Useful results from this work

- The peer setup can run isolated multi-node proofs and check process cleanup.
- Core activation, Ref identity, and persistence can be reused. No second checkpoint format is needed.
- A cold-host restore failure was found and fixed in core, which owns decoding and activation order. See the [alignment review](alignment.md).
- Local resources remain local after placement. A cluster runtime must account for them before selecting a target.
- The current keyed manager supplies connected-node routing, but it does not supply durable write authority or automatic background recovery.

These are integration results. They justify the foundation and test setup. They do not yet justify claims about automatic scheduling, draining, admission, or partition-safe replacement.

## Proposed package purpose

Turn declared Topology requirements into maintained placement across changing hosts. Own the current host inventory, capacity admission, bounded placement operations, drain policy, and replacement coordination. Report desired placement, observed placement, readiness, and uncertain outcomes through a public status contract. Use core for execution and exact-node activation.

Use a core control Agent and Plugin when those contracts fit. Define one repair owner: the cluster coordinator must not compete with core repair for the same activation. A second Topology executor is not required to prove this purpose.

Keep the keyed manager as a separate supported foundation until its Ref mapping and lifecycle relationship are decided. Do not silently migrate its persistence IDs.

## Five stronger acceptance examples

| Example | Trigger and expected result | What the test must stop doing |
| --- | --- | --- |
| Requirements to maintained placement | Submit a Topology with compute requirements. The runtime selects compatible live hosts, starts the Agents, and reports readiness. Unavailable compatible capacity produces an explicit waiting or rejected result. | Select exact nodes or patch the definition on behalf of the runtime |
| Automatic connected-host recovery | Stop a worker host. With compatible spare capacity available, the runtime replaces the worker, retains its Ref and checkpoint, and reports recovery completion. | Stop and replace the Controller itself |
| Drain a live node | Request drain while the host remains connected. New admission excludes that host. Existing workers move through bounded operations. Drain completes only after owned activations and reservations are released. | Move each Agent separately |
| Capacity admission and failed-start cleanup | Submit more workers than the declared capacity. Reservations prevent excess activation. A failed start releases its reservation, and pending work can proceed. | Enforce capacity through test setup or sequential launches |
| Reconcile an uncertain operation | Delay a start or move result, then restart its cluster operation owner. Status identifies the uncertain operation and reconciles the observed activation and reservation. A timed-out Signal is not replayed automatically. | Treat an RPC timeout as confirmed failure or construct the reconciliation manually |

Each row is proposed work. Write contract tests for its state transitions and failure cases before implementing its runtime. Keep the existing examples as core-boundary checks until runtime examples replace their manual coordination.

## Next slice and release limit

Start with requirements to maintained placement on fixed connected nodes. Add a public cluster lifecycle and status surface that consumes the existing extension metadata. Prove compatible selection, no-capacity handling, readiness, and cleanup. Then prove host-loss coordination with one repair owner. Dynamic infrastructure is not needed for either proof.

Admission and drain are useful within the connected-node mode. Neither grants exclusive write authority during partitions. Before claiming safe replacement across disconnected views, add a separate stale-writer proof at the protected storage operation: a previous activation must be unable to commit after a newer authority holder is accepted. Core CAS and a local manager-count check do not establish that guarantee.

Return to [package purpose](README.md) or [decision questions](questions.md).

## Implemented next slice

The [03 Placement examples](../../../examples/03_placement/README.md) now prove maintained placement through `Jido.Cluster.Scheduler`. The original review above describes the first example group; it is retained to explain why this slice was added.

| Proposed proof | Current evidence | Remaining scope |
| --- | --- | --- |
| Requirements to maintained placement | Runtime selects compatible connected hosts; namespace mismatch rejects startup | Discovery adapters and release/resource compatibility |
| Automatic connected-host recovery | Host-loss status is uncertain, with no replacement writer | Confirmed source retirement and protected-write authority |
| Drain a live node | Per-Scheduler drain selects and applies a cooperative move | Global drain and interrupted-operation reconciliation |
| Capacity admission and failed-start cleanup | Complete slot admission; namespace rejection releases planned slots before startup | Global reservations and partial-activation failure reconciliation |
| Reconcile an uncertain operation | Source loss remains visible after inventory changes | Durable operation identity and operation-owner restart |

Worker exit has its own example: the Scheduler requests one bounded core repair pass and retains the Ref and checkpoint. This is different from host replacement. Read the [implementation alignment](alignment.md) and [guide](../../../guides/placement.md) for the supported limits.
