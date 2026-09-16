# Current implementation and proposed API alignment

Status: source review on 2026-09-15. Cluster source was read at commit
`9958886` (`fix(scheduler): own coordinator cleanup and restore accepted placement`).
This documentation change does not run or claim a new runtime test result.

The placement guide (retired path: `../../../../guides/placement.md`) is the current public runtime
contract. The [design](design.md) proposes a larger API and does not replace it.

## Existing package evidence

| Seam | Current source and evidence | Gap to this proposal |
| --- | --- | --- |
| Top-level namespace | [Jido.Cluster](../../../../lib/jido_cluster.ex) reports visible nodes | No supervised service, target configuration, or proposed facade functions |
| Declared placement | Scheduler (retired path: `../../../../lib/jido_cluster/scheduler.ex`), planner (retired path: `../../../../lib/jido_cluster/scheduler/planner.ex`), requirements example (retired path: `../../../../test/examples/03_placement/03_01_requirements/requirements_test.exs`) | Root singleton Agents and fixed hosts; no target catalog or dynamic acquisition |
| Authoring | [Cluster extension](../../../../lib/jido_cluster/topology/extension.ex), [extension tests](../../../../test/jido_cluster/topology/extension_test.exs) | Static `cluster_worker` labels; no separate `placements` section or target binding |
| Admission | [Planner tests](../../../../test/jido_cluster/deployment/planner_test.exs), admission example (retired path: `../../../../test/examples/03_placement/03_02_admission/admission_test.exs`) | Per-Scheduler slots; no shared target admission authority |
| Connected owner | Scheduler owner (retired path: `../../../../lib/jido_cluster/scheduler/owner.ex`), coordinator example (retired path: `../../../../test/examples/03_placement/03_06_coordinator/coordinator_test.exs`) | Connected exclusion and cleanup; no durable ownership grant or provider resources |
| Accepted placement | Operation (retired path: `../../../../lib/jido_cluster/scheduler/operation.ex`), restart example (retired path: `../../../../test/examples/03_placement/03_07_restart/restart_test.exs`) | Reads effective core nodes; restart with changed initial inventory is not covered |
| Movement | Drain example (retired path: `../../../../test/examples/03_placement/03_03_drain/drain_test.exs`) | One Scheduler scope; drain intent and operation state are not durable |
| Repair and host loss | Worker repair (retired path: `../../../../test/examples/03_placement/03_04_worker_recovery/recovery_test.exs`), host loss (retired path: `../../../../test/examples/03_placement/03_05_host_loss/host_loss_test.exs`) | Bounded connected repair; lost source remains uncertain |
| Keyed Agents | InstanceManager (retired path: `../../../../lib/jido_cluster/instance_manager.ex`), peer tests (retired path: `../../../../test/jido_cluster/distributed/v3_foundation_test.exs`) | Manager/key API and encoded IDs; no unified distributed Ref directory |
| Persistence | Mnesia adapter (now `Jido.Persistence.Mnesia` in core) preserves core byte records and CAS | No cluster operation journal or protected-write authority protocol |
| Host observations | Scheduler (retired path: `../../../../lib/jido_cluster/scheduler.ex`) filters configured inventory by connected nodes; Operation (retired path: `../../../../lib/jido_cluster/scheduler/operation.ex`) checks namespace parity | No host reporter, report generation, freshness probe, release compatibility, or measured load policy |
| Signal federation | [Local Bus guide](https://github.com/agentjido/jido_signal/blob/8d361dfe623c8560242e4ce517122dac7460ed8e/guides/event-bus.md), [Bus](../../../../../jido_signal/lib/jido_signal/bus.ex), [PubSub dispatch](../../../../../jido_signal/lib/jido_signal/dispatch/pubsub.ex) | Local Bus and generic transport exist; no cluster mirrors, channel protocol, Ref subscription directory, or cross-host delivery guarantees |

Coordinator exclusion, cleanup after Scheduler exit, and accepted-placement reads
are now part of the current source. Do not describe the earlier lifecycle probes
as unresolved defects without testing the current implementation.

## Core seams

| Core contract | Consequence |
| --- | --- |
| [Agent Ref](../../../../../jido/lib/jido/agent/ref.ex) | Reuse exact identity; location and authority remain separate |
| [Topology instance](../../../../../jido/lib/jido/topology/instance.ex) and [plan](../../../../../jido/lib/jido/topology/plan.ex) | Derive Agent IDs from core, including expansion when supported |
| [Topology extension](../../../../../jido/lib/jido/topology/extension.ex) | Static authoring only; provider acquisition belongs in the runtime |
| [Controller](../../../../../jido/lib/jido/topology/controller.ex) | Exact-node activation and cooperative movement already exist; select manual repair with one cluster owner |
| [Ref facade](../../../../../jido/lib/jido/instance/ref_facade.ex) | Current resolution is local; distributed directory and routing belong in cluster |
| [Persistence adapter](../../../../../jido/lib/jido/persistence/adapter.ex) | Atomic CAS is available, but it is not an ownership grant |

Core is sufficient for another root-singleton connected placement slice. Do not
change core merely to add a provider name. A provider must yield a real compatible
BEAM node for the existing activation contract.

Potential core work needs a separate example and change in its own repository:

- A consistent accepted-target snapshot with a revision for restart and partial
  reconciliation. Public effective-node reads already support the current slice.
- Validated initial placement overrides for expanded groups, includes, and
  Plugin-added Agents. Patching root definitions does not establish this support.
- Authorized lost-source replacement after protected storage rejects the old
  writer. An arbitrary force flag is not that contract.

The [host intelligence](host-intelligence.md) and
[Signal federation](signal-federation.md) companions extend the proposal. Current
Signal Bus storage is memory-only by default. Core still rejects a remote topology
Agent subscribing to a Controller-owned local Bus. Neither a PubSub transport nor
new authoring metadata bypasses that rule.

Local mirrors, host reporters, validated probe freshness, shared admission, and
movement-aware federation bindings require new cluster runtime work. The companions
provide test gates; they do not claim that the existing examples cover those gates.

## AI and LitterBox boundary

Current [Jido.Session](../../../../../jido_ai/lib/jido_session.ex) owns interaction
history through a Thread. Its module documentation explicitly excludes process,
live request, stream, AgentServer, and persistence-adapter ownership. Reusing it
would not supply a compute placement lifecycle.

LitterBox's [architecture](https://github.com/zblanco/litter_box/blob/main/ARCHITECTURE.md)
and [Session](https://github.com/zblanco/litter_box/blob/main/lib/litter_box/sandbox/session.ex)
describe a different compute-resource contract. Use these as prior art, not as
evidence that Jido placement already works through a LitterBox backend.

Relevant backend observations from the source review:

- [Docker](https://github.com/zblanco/litter_box/blob/main/lib/litter_box/sandbox/backends/docker.ex):
  `provision` constructs resource metadata; `open_session` starts the stateful
  container. A narrow extraction must retain the actual creation and cleanup path.
- [Sprites](https://github.com/zblanco/litter_box/blob/main/lib/litter_box/sandbox/backends/sprites.ex):
  opening can create or find a hosted resource; closing deletes only when the
  session's create policy is ephemeral. Releasing use and destroying a resource
  are different operations.
- The backend facade covers execution, files, attach, checkpoints, services,
  proxies, and other operations beyond topology host placement. Whole-backend
  copying would bring that broader scope into this package.

This proposal adds no backend dependency and imports no upstream code. The native
provider contract, operation journal, Docker implementation, and hosted-node
network and lifecycle behavior all still need implementation and proof.
