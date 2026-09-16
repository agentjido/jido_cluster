# Core V3 and package alignment

Status: source review. Proposed work is not marked as implemented.

Reviewed on 2026-09-15:

- `jido_cluster`: `v3-spike`, commit `c2253ff` before this documentation change.
- Sibling `jido`: `release/v3`, commit `54247adbb787428b112ca8c19e9a63b16ccd0194`.
- [Issue #19](https://github.com/agentjido/jido_cluster/issues/19), including its comment thread: no comments at review time.
- [Issue #1](https://github.com/agentjido/jido_cluster/issues/1): scenario discussion.

Core source links below use the sibling checkout. This workspace contains separate repositories. No core files were changed for this review.

## Core boundary

The core [Topology control-plane briefing](../../../../../jido/docs/design/11_topology-control-plane/README.md) and [implemented alignment](../../../../../jido/docs/design/11_topology-control-plane/alignment.md) explicitly leave distributed policy outside core. The [detailed design](../../../../../jido/docs/design/11_topology-control-plane/design.md) lists `TOP-REQ-006` through `TOP-REQ-058` and `TOP-REQ-061` as external reference requirements. They are input to this package design, not proof that this package implements them.

| Core seam | Current contract | Consequence for this package |
| --- | --- | --- |
| [Agent Ref](../../../../../jido/lib/jido/agent/ref.ex) | Exact namespace, optional partition, and ID; no process, node, module, or authority | Reuse identity; design location and authority separately |
| [Jido lifecycle](../../../../../jido/lib/jido.ex) | Local instance supervision, Ref activation, calls, inspection, and persistence integration | Coordinate through public lifecycle calls; keep Agent semantics in core |
| [Topology Controller](../../../../../jido/lib/jido/topology/controller.ex) | Repairs the current target, accepts additive Agent updates, and applies a caller-selected node with `place_agent/4` | Cluster selects the node; define one repair owner; do not assume arbitrary target removal is supported |
| [Remote activation](../../../../../jido/lib/jido/topology/controller/activation.ex) | Exact node via RPC; timeout or disconnect can return uncertain placement | Reconcile uncertain outcomes; no silent local fallback |
| [Topology extension](../../../../../jido/lib/jido/topology/extension.ex) | Pure static lowering, common validation, no services or process startup | An authoring extension cannot perform live scheduling |
| [Persistence adapter](../../../../../jido/lib/jido/persistence/adapter.ex) | Atomic byte or opaque-token compare-and-swap; unknown required write results stop the activation | Preserve required-write behavior; CAS is not an ownership epoch |
| [Persistence record](../../../../../jido/lib/jido/persistence/record.ex) | Core identity validation, checkpoint encoding, revisions, and tombstones | Do not add a separate cluster checkpoint format |
| [Remote child guide](https://github.com/agentjido/jido/blob/54247adbb787428b112ca8c19e9a63b16ccd0194/guides/ownership-orphans-and-remote-children.md) | Explicit remote child lifecycle with local relationship limits | Separate parent-child ownership from distributed write authority |

Remote Topology Agents cannot use a Controller-owned local Bus. Node-local ETS, files, Registry entries, and Bus instances do not become shared resources because an Agent moves. A provider must prove runtime and resource compatibility before it reports readiness.

Core has useful activation mechanisms, not a general distributed scheduler. Its Controller placement test is evidence of exact-node mechanics: [controller_placement_test.exs](../../../../../jido/test/jido/topology/controller_placement_test.exs). That suite was inspected for the design review. It is also run with the cold-restore regression for the Topology example slice.

## Current package

| Capability | State and evidence | Limit |
| --- | --- | --- |
| Keyed routing | InstanceManager (retired path: `../../../../lib/jido_cluster/instance_manager.ex`); peer tests (retired path: `../../../../test/jido_cluster/distributed/v3_foundation_test.exs`) | Manager/key interface; no public distributed Ref directory |
| Eligible membership | Live managers in a `:pg` group; configuration parity checked before work | No discovery adapter, labels, capacity, or persistent membership generation |
| Placement | Topology helper (retired path: `../../../../lib/jido_cluster/topology.ex`) uses rendezvous hashing | Selection only; standby output is not a live replica |
| Connected movement | Per-key `:global.trans`; old connected activations are stopped before new work | No durable authority across disconnected views |
| Local activation | LocalManager (retired path: `../../../../lib/jido_cluster/internal/local_manager.ex`) starts temporary core Agents under a manager-owned Jido instance | Recovery is requested by later manager work; no independent recovery queue |
| Quorum guard | Manager-count check and periodic local activation shutdown | Local view and detection delay; no stale-writer fencing at storage |
| Saved-state recovery | Mnesia adapter (now `Jido.Persistence.Mnesia` in core), core records, replicated RAM example | Application owns Mnesia topology; local ETS cannot provide cross-node recovery |
| Delivery | Call returns committed Agent; cast acknowledges enqueue; no automatic Signal retry | RPC timeout can have an unknown result |
| Test setup | [ClusterCase](../../../../test/support/cluster_case.ex) has isolated peers and separate control channels | Existing peer tests cover connected loss, not asymmetric partition authority |
| Living docs | Counter example (retired path: `../../../../examples/01_cluster/01_01_keyed_counter/README.md`) and mirrored example tests | No FLAME, cloud, or fenced-write evidence |
| Topology scheduling | Scheduler (retired path: `../../../../lib/jido_cluster/scheduler.ex`), planner (retired path: `../../../../lib/jido_cluster/scheduler/planner.ex`), and placement examples (retired path: `../../../../examples/03_placement/README.md`) | Root singleton Agents; configured inventory filtered by connected membership |
| Admission and drain | Complete per-Scheduler slot selection before startup; serialized connected-node drain through core | Greedy packing, no global reservation store, and no global node drain |
| Worker repair | Scheduler requests bounded manual core repair after worker exit | One operation per detected exit; uncertain outcomes require explicit retry |

The previous implementation is retained under `archive/v2/`. Its rebalancer, replicas, adapters, and tests are historical reference. They are not active V3 features.

## Design gaps

1. Define Ref mapping without changing existing keyed persistence identities.
2. Choose how independently keyed Agents and declared Topology Agents share placement policy while each has one lifecycle owner.
3. Separate desired placement, location observation, and authority records.
4. Select and prove protected-write fencing before claiming safe exclusive replacement during partitions.
5. Define provider lifecycle ownership without calling it a durable writer lease.
6. Add bounded admission and recovery before dynamic capacity and automatic rebalance.
7. Define compatibility and resource-locality checks before remote readiness.
8. Define public operation states and operator controls before exposing long-running moves.

See [questions](questions.md) for proposed decisions and proof gates.

## Topology example slice

The Topology examples (retired path: `../../../../examples/02_topologies/README.md`) now define the first test-driven slice: eligible selection, static label lowering, cooperative movement, explicit recovery after confirmed host exit, and local Bus rejection. [Placement unit tests](../../../../test/jido_cluster/placement/selection_test.exs) and [extension tests](../../../../test/jido_cluster/topology/extension_test.exs) cover the pure policy boundary.

The source contract is intentionally small. Inventory comes from the application. Label requirements use Topology metadata. No discovery, authority provider, automated recovery service, or distributed Bus is selected by this slice. The existing decision questions remain open beyond these examples.

The move and recovery examples exposed cold-host checkpoint decoding before the Agent definition loaded. Core now loads the definition first. The [core regression](../../../../../jido/test/jido/topology/controller_cold_restore_test.exs) uses copied checkpoint bytes and an unloaded Agent module on a fresh node; it fails before the order change and passes afterward. The safe decoder and record format stay unchanged.

Verified local core fix: `9f4cc2b0fab3893285938d33b4fbaa225d5d5984`. This change is separate from the cluster repository and is not pushed by the example work.

## Maintained placement slice

The 03 Placement group (retired path: `../../../../examples/03_placement/README.md`) now uses a public cluster lifecycle instead of test-selected nodes. The application supplies host labels and per-Scheduler capacity. The runtime checks connected availability and namespace parity, selects the entire plan, and starts a manual core Controller. Inventory updates retry admission. Drain and worker repair use the same serialized operation path.

The [planner tests](../../../../test/jido_cluster/deployment/planner_test.exs) check slot limits, stable placement, invalid inventory and requirements, and unsupported groups. The Scheduler tests (retired path: `../../../../test/jido_cluster/scheduler_test.exs`) check ownership exclusion, rejected updates, absent instances, disconnected configured hosts, and blocked cleanup. Example tests check behavior on real peer nodes, committed work, Ref continuity, and worker cleanup.

The host-loss example deliberately stays uncertain, even after compatible spare capacity is added. Core `place_agent/4` requires confirmed retirement of the current source. An unreachable source returns `:placement_uncertain`. The package does not bypass that contract or infer write authority from node loss.

Global admission, durable operations, operation-owner restart, arbitrary resource compatibility, and automatic host replacement remain gaps. The current public contract is in the placement guide (retired path: `../../../../guides/placement.md`).
