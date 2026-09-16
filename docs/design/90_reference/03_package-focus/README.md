# Package focus: placement across topologies

Current direction: [Architectural vision](../../00_architecture/README.md)
and [Delivery slices](../../00_architecture/delivery-plan.md) supersede this document's
scope and sequence where they differ. Federation is now in scope, before dynamic
providers. Fabric capabilities may be consolidated into Cluster.

Status: recommended revision on 2026-09-15. This is a design proposal, not an
implemented contract or an accepted release decision. It revises the scope and
delivery order in [02 Top-level API](../02_top-level-api/design.md).

The later [architectural vision](../../00_architecture/README.md) broadens
the package description to connected Agent placement, including the future keyed
demand boundary with Fabric. The static-host proof sequence below remains the
recommended first delivery scope.

## Purpose

**Jido Cluster coordinates placement and capacity for Jido topologies across a
pool of compatible BEAM hosts.**

Applications declare what must run and its placement constraints. Cluster admits
that demand against a shared capacity scope, selects hosts, and coordinates
placement changes. Core Jido performs activation, execution, readiness, checkpoint
restore, and cooperative movement.

The package earns its place when two or more topology instances compete for
capacity, or when an operator must evacuate a host without writing a separate
coordination system. An application with fixed exact-node placement and no shared
admission needs can use the core Controller directly.

## Critique of the previous proposal

| Concern | Why it weakens the design | Recommended change |
| --- | --- | --- |
| Providers arrive before shared admission | Starting a Docker host proves resource mechanics, but does not prove control of a shared pool | Prove multiple deployments on static hosts first |
| Per-deployment limits look like host capacity | Two correct Schedulers can each reserve the same physical capacity | Make one declared admission scope the central contract |
| A large facade arrives before lifecycle proofs | Wrappers around core calls can hide unresolved ownership and restart behavior | Add public operations only with a complete lifecycle test |
| Host intelligence becomes a second project | Load ranking, detailed measurements, and probes expand scope before basic claims are sound | Require only bounded eligibility evidence and configured slots first |
| Federation becomes a release pillar | Event delivery has separate buffering, loss, restart, and subscription contracts | Defer it to a separate integration proposal |
| Keyed activation and topology deployment are parallel entry points | Their identity and repair rules could diverge | Make topology placement the new design path; retain the existing keyed API without extending it |
| Durable records appear optional for operational control | Lost drain intent and claims make restart behavior difficult to explain | Require a placement journal before claiming restart-safe shared control |

Keep the strong parts: core Refs, one placement owner per topology, explicit
uncertainty, no implicit replay of Agent work, and a distinction between host
readiness and Agent readiness.

## Place in the ecosystem

| Package or service | Responsibility |
| --- | --- |
| `jido_action` | Executable Actions and instruction execution |
| `jido_signal` | Signal values, local routing, local Buses, and transport adapters |
| `jido` | Agent identity, state, execution, persistence contract, and topology activation mechanisms |
| `jido_cluster` | Shared admission, placement policy, host eligibility, placement operations, and observed locations |
| `jido_ai` | Model calls, tools, and AI Agent behavior; an optional consumer of placed capacity |
| Applications such as Jidoka | Sessions, business workflows, tenant policy, and decisions to request more work or capacity |
| Infrastructure integrations | Host acquisition, inspection, and release through a later provider boundary |
| Protected storage and authority service | Rejection of stale writers when exclusive replacement is required |

Cluster depends on core. Core must remain usable without Cluster. AI packages and
applications can use Cluster without Cluster depending on their domain concepts.
Applications choose trusted releases, persistence deployment, and external-effect
policy. Cluster does not become a workflow engine, sandbox API, or release builder.

## The owned contract

The central object is an **admission scope**: one identified pool of host slots,
managed topology instances, and capacity claims. A service name is an entry point,
not a new capacity scope. Two service instances cannot independently admit against
the same scope.

1. Validate a supported core topology and its placement constraints.
2. Check eligible hosts and reserve all required slots before initial activation.
3. Ask one manual core Controller to activate on the selected nodes.
4. Record accepted placement and publish locations only after readiness checks.
5. Serialize moves, repair, drain, and stop against those claims.
6. Retain claims while retirement, activation, or cleanup is uncertain.
7. Reconcile recorded intent, core placement, and live observations after restart.

Complete admission does not make activation atomic. A failed partial deployment
must report remaining Agents, claims, and cleanup work. A move needs transition
capacity. A host drain spans every managed deployment that uses that host and
blocks new admission there until the drain is explicitly cleared.

One scope owns each host's configured slot budget in the first release. Overlapping
target labels do not create extra slots. Disjoint scopes may use explicitly
partitioned budgets; unmanaged Agents and external processes are outside those
budgets. Slot accounting is not a CPU or memory guarantee.

Use one connected admission coordinator for a scope in the first implementation.
The existing topology owner still excludes competing owners of the same namespace
and topology ID. A journal records intent and claims; it does not elect an owner.
An unreachable coordinator blocks new admission. Do not start a replacement on
another partition based on a timeout. Restart must establish cleanup or retain
uncertainty before it changes claims.

Identity, location, and authority remain separate. Reuse core Refs and core Agent
IDs. Keep the location view limited to managed topologies. Reading a location does
not activate an Agent or grant permission to write. A routed call does not retry
after an unknown result.

## First release boundary

Support connected, application-managed BEAM hosts and root singleton topologies.
Require configured slots, labels, namespace compatibility, and a minimal prepared
runtime identity. A missing or stale eligibility check blocks new placement; it
does not prove that an existing Agent stopped.

The first release must prove shared admission, scope-wide drain, visible operation
progress, and journal-backed restart reconciliation. It need not support automatic
coordinator failover. Select the journal adapter, scope identity, and coordinator
restart protocol through contract tests before implementing the facade.

Keep the first authoring surface small. Preserve current `cluster_worker` labels.
Named static targets can group host policy, but must resolve to the same underlying
slot inventory. Defer a second placement DSL until concrete examples require it.

The first public operations are plan, deploy, status, drain, stop, operation lookup,
and bounded reconciliation. Ref lookup and routing support those deployments.
An explicit move API can follow the same protocol after drain proves it. Request
IDs identify placement operations, never business work. Planning reserves nothing.

Defer dynamic acquisition, automatic scaling or rebalancing, load-based ranking,
expanded topology forms, federation, and partition-safe replacement. Each can
extend the package only after its prerequisite contract has evidence.

## TDD and example sequence

Keep examples under `test/examples/` with `@moduletag :example`. Use ordinary
non-AI Agents, so the package's value is clear without model or tool behavior.

| Order | Living example | Required proof |
| --- | --- | --- |
| 1 | Two topologies, one final slot | Concurrent requests admit only one; the rejected topology starts no Agent |
| 2 | One host, two deployments | Stopping one releases only its claims and retains the other deployment |
| 3 | Drain a shared host | Both topologies move through core; new admission excludes the source; Refs and checkpoint state remain stable |
| 4 | Restart during partial drain | Completed moves remain accepted; remaining claims and drain intent survive; no duplicate activation or false success |
| 5 | Lose a host during movement | Status remains uncertain; claims stay held; spare capacity does not trigger unauthorized replacement |

Unit tests cover deterministic selection, request conflicts, slot accounting,
eligibility expiry, and operation transitions. Local Erlang peer tests cover races,
ownership, cleanup, restart, and movement. Assert public outcomes and live process
evidence, not only the coordinator's internal counters.

After these pass, add a provider example: insufficient static capacity acquires one
owned host, verifies readiness, runs work, and releases that host only after all
claims and Agent cleanup settle. This extends a proven placement protocol.

## Current evidence and migration

The current Scheduler (retired path: `../../../../guides/placement.md`) already proves placement,
per-Scheduler admission, connected ownership, cooperative drain, and bounded repair.
It does not implement shared admission or durable drain records. Existing examples
remain useful lower-level proofs; the five examples above are new acceptance gates.

Keep `InstanceManager` behavior and persisted key encoding compatible. Do not fold
it into the new facade until its identity and lifecycle mapping has separate tests.
Preserve current APIs while the shared coordinator is built behind new contracts.
Do not label the larger proposal implemented because its facade exists.

The [previous proposal](../02_top-level-api/design.md) remains a catalog of possible
APIs and provider rules. Its delivery order and federation scope are superseded by
this recommendation. Host intelligence is reduced to eligibility for the first
release. Federation requires a separate ownership decision before implementation.
