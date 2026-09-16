# S7 — Entity identity within Cluster

> Current scope after legacy removal: applications use named `Jido.Cluster`
> instances and `Jido.Cluster.Entity`. The standalone manager, standalone
> Scheduler, offline checkpoint importer, example groups 01–03, and V2 archive
> have been removed. `Deployment` is private runtime code under the named scope.
> Earlier statements and test counts below describe historical checkpoints.


Status: the bounded implementation and local example acceptance pass. The
original proposal below was written on 2026-09-15; read the
[implementation record](#s7-implementation-and-acceptance) for current behavior.
Document review remains pending approval. See [scope and dependencies](README.md).

## Outcome

Bring useful Fabric concepts into Cluster without requiring a separate package.
Route domain keys through the same admitted placement and lifecycle path.

## Implementation steps

1. Review the old Fabric implementation against V3. Extract fixtures for identity
   validation and persisted key compatibility before porting code.
2. Specify an entity workload scope and deterministic domain-key to core-Ref
   mapping. Test that restart and movement do not change storage identity.
3. Define bounded on-demand activation within that scope. Choose the core topology
   integration seam before coding; do not create a second workload graph.
4. Route candidate selection through shared admission. A hash result never bypasses
   an accepted placement or starts a competing activation.
5. Add entity lookup and call behavior with explicit missing, pending, and uncertain
   results. Preserve core call semantics and never automatically replay work.
6. Integrate entity claims with drain and journal recovery. Keep the legacy manager
   separately scoped until its migration path is proved.
7. Add a device-entity example and a mixed entity/topology capacity test.

## Contracts and lifecycle

Domain keys are application values mapped into exact core namespace and Ref
identity. Store the mapping version and workload definition identity. Do not
silently change the legacy manager's persisted encoding.

Use the same placement owner, claims, directory, and journal as topology demand.
Choose activation granularity from a bounded benchmark; a Controller per entity
is not assumed. If core lacks a suitable public seam, specify and test that change
in core before extending the Cluster runtime.

## Failure handling

- Duplicate first requests: create one admitted activation.
- Insufficient capacity: reject or report pending under an explicit bounded policy.
- Stale candidate location: resolve accepted placement or report uncertainty.
- Incompatible old identity: reject migration rather than cold-starting new state.
- Host loss: retain the same uncertainty rules as topology deployments.

## Tests and completion

Test identity encoding and migration fixtures, concurrent first activation,
shared admission with a declared topology, restart, and cooperative movement.
The device example retains its Ref and committed state across a move. Measure
activation overhead at a stated bounded entity count before claiming scale.

Done when entity routing uses one placement path, the budget cannot be bypassed,
and existing persisted identity remains accessible under the supported migration.

Write the unit contracts first, then local peer tests, then the tagged living
example. Run relevant package format, compile, quality, and test checks. Record
actual results and evidence links here before marking this slice complete.

## Example-based acceptance plan

Status: this is the original acceptance plan. All four numbered examples now
exist and pass locally; see the [current evidence](#s7-implementation-and-acceptance).
Follow the [shared example test method](../00_architecture/example-testing.md).

Proposed group: `examples/10_entities/`, mirrored under
`test/examples/10_entities/`. These numbers extend the existing 01–03 groups;
confirm they remain free before implementation. Keep scenario IDs stable once added.

### Setup

Use a device workload, two worker peers, a shared admission scope, and explicit
persistent identity fixtures from the old manager. Use ordinary non-AI Agents
whose state records a count and last accepted domain event.

### Scenarios

| Proposed example | Actions | Required observations |
| --- | --- | --- |
| `10_01_first_activation` | Submit simultaneous first calls for one device identity from independent peers. | One admitted activation and one core Ref serve the identity. Calls observe the documented core commit behavior; no duplicate activation appears. |
| `10_02_entity_move` | Commit device state, drain its host, then route another event by the same domain key. | Ref and persistence identity stay stable; the new accepted location continues the state. Candidate hashing cannot bypass a pending move. |
| `10_03_mixed_demand` | Fill a shared pool with declared topology demand, then request a new entity. | Entity activation cannot bypass the budget. After a confirmed release it can be admitted through the same owner. |
| `10_04_identity_compatibility` | Load a supported old persisted identity and resolve it under the declared mapping version. | Existing state remains accessible. Unsupported mappings fail explicitly instead of silently creating a fresh entity. |

### Evidence and failure control

Use explicit unique event IDs to distinguish test submissions; do not infer
application deduplication from one live Agent. Validate candidate selection against
accepted placement through public APIs. Keep scale measurement separate from the
functional example and publish its exact entity count and resource setup. No
follower, partition-safe replacement, or durable event-ack guarantee is implied.

### Promotion record

For each scenario, add links to its source, README, and executable test. Record
the command, seed, backend, result, and cleanup result. Map every README guarantee
to an assertion. A fake-only result cannot prove an external backend contract.
Keep this slice incomplete until its required examples and lower-level contracts
pass; record unavailable cases explicitly.

## Cross-slice refinements

Split the mapping work from the full feature implementation. Run a small design
probe during S1, before S2/S3 schemas become fixed. Read current core topology
activation/expansion APIs and specify workload identity, Ref mapping, persistence
identity, activation granularity, and placement owner. Record unsupported cases.

The full implementation remains S7. It uses the same resource-conflict model and
bounded journal contract; it must not put every entity in a scope aggregate without
measuring the supported count. If the required core seam is absent, document and
prove that gap before introducing another topology or activation system.

Use [the mapping requirements](../00_architecture/lifecycle-contracts.md) as the
probe's acceptance criteria. Retain old key fixtures and test explicit migration.
Do not turn this early probe into a promise of replica or partition semantics.

## Final build refinements

Keep candidate hashing separate from accepted routing, as reinforced by the
Hyper review. Add delayed-registration and unknown-start cases to the early probe;
neither can create a second activation. Include entity cardinality in the journal
size experiment before selecting a supported workload bound.

## Decisions and limits

Replica synchronization, follower reads, durable event acknowledgement, and
partition-safe replacement remain excluded. Preserve the old Fabric repository
as reference until imported behavior has tests; no wholesale source copy or new
mandatory dependency is planned.

## Early mapping probe — implementation evidence

`test/jido_cluster/entity_mapping_probe_test.exs` reads the current public core
constructor and Cluster placement seam. With four type-distinct domain keys, the
probe constructs a versioned workload ID and verifies that exact-node placement
preserves core's generated Agent ID and Ref. Claims can therefore identify scope,
core workload ID, Ref, host allocation/incarnation, and placement operation without
introducing an independent Agent ID scheme.

Current limits: Cluster's Planner rejects groups, includes, and Plugin-added
Agents. Core can construct expanded groups, but the current Cluster placement
seam does not admit them. One fixed singleton workload per entity is a possible
bounded integration, not a selected scale contract. S7 still needs a measured
activation-granularity decision and the full capacity/recovery tests.

Legacy `InstanceManager.agent_id/1` uses `key:` plus deterministic external-term
bytes. A core topology Agent ID also includes the escaped topology ID and the
Agent declaration path. Those IDs differ. No transparent legacy migration is
claimed; S7 must add an explicit mapping/migration contract and fixtures before
routing old identities through the new path. Pending location and unknown-start
cases use the S1 request barrier and must be extended with S2 host-claim tests.

## S7 implementation and acceptance

The [entity facade](../../../lib/jido_cluster/entity.ex) declares a versioned
workload definition, optional keyspace, Agent module, labels, and initial state.
The [identity encoder](../../../lib/jido_cluster/entity/identity.ex) maps a
portable domain key to one deterministic core Topology ID. It limits the encoded
source to 180 bytes so the encoded Topology ID fits core's 255-byte key limit.
It rechecks canonical version-one IDs before admission.
When a keyspace is set, the old Fabric tuple rule applies: the first tuple
element must equal that keyspace. The definition ID is stored in Topology
metadata and the scope journal. Core derives the Agent ID and Ref. The mapping
does not use a host name or process ID.

Each admitted identity is one root singleton core Topology. The scope
[service](../../../lib/jido_cluster/instance/service.ex) serializes concurrent
first requests and submits one deployment through its existing `:deploy` path.
Shared [admission](../../../lib/jido_cluster/admission.ex), journal, host claims,
drain, and recovery apply without a second workload graph. The entity limit is
eight running identities per scope; the aggregate journal still limits the
scope to 16 deployments. A stopped ID remains recorded and cannot be started
again in that scope. There is no automatic eviction.

The facade separates `ref`, `lookup`, `ensure`, and `call`. Lookup does not start
an Agent. A missing Ref is `:not_found`; an accepted but unready Ref is
`:pending`; a store or location with unknown state is `:uncertain`.
`Entity.call/5` waits for admission readiness and submits its Signal once
through the core call path. It does not replay a timed-out Signal. A failed
capacity check creates no entity claim.

The offline importer (retired path: `../../../lib/jido_cluster/entity/legacy_migration.ex`)
reads the exact `InstanceManager.agent_id/1` checkpoint, copies its complete
Agent state and revision to the new core ID, and writes the core Topology
ownership marker. It refuses an existing target record. The source record
remains for rollback. Stop old writers and the target Cluster before the copy:
the two records do not form one atomic transaction. Workloads with
`identity_mode: :require_imported` reject a missing target checkpoint rather
than start empty. A version outside `:v1` fails validation. The old manager is
still a separate API and has no shared admission claim.

Implemented requirements and direct evidence:

| Requirement | Current evidence |
| --- | --- |
| CL-ENTITY-REQ-001: The identity encoder shall map each valid key and definition ID to one stable version-one Topology ID. | [Identity tests](../../../test/jido_cluster/entity_test.exs) and migration fixture (retired path: `../../../test/jido_cluster/entity_migration_test.exs`) |
| CL-ENTITY-REQ-002: When first requests for one key arrive together, the scope service shall admit one activation. | [Concurrent peer example](../../../test/examples/10_entities/10_01_first_activation/first_activation_test.exs) |
| CL-ENTITY-REQ-003: When declared demand holds the last slot, the scope service shall reject new entity activation without a claim. | [Mixed-demand example](../../../test/examples/10_entities/10_03_mixed_demand/mixed_demand_test.exs) |
| CL-ENTITY-REQ-004: When Cluster drains a live entity host, the entity shall keep its core Ref and committed state. | [Move example](../../../test/examples/10_entities/10_02_entity_move/entity_move_test.exs) |
| CL-ENTITY-REQ-005 (retired): offline legacy checkpoint import. | Removed at user request; current workloads reject `:identity_mode`. |
| CL-ENTITY-REQ-006: While activation is pending, an entity call timeout shall not submit its Signal. | [Pending activation test](../../../test/jido_cluster/entity_pending_test.exs) |
| CL-ENTITY-REQ-007: When a journaled scope restarts, entity lookup shall remain uncertain until reconciliation restores the retained claim. | [Recovery test](../../../test/jido_cluster/entity_recovery_test.exs) |
| CL-ENTITY-REQ-008: If an entity admission write reply is lost, then the scope service shall reconcile the recorded activation without starting a second Agent. | [Lost-reply recovery test](../../../test/jido_cluster/entity_recovery_test.exs) |

The [four numbered examples](../../../examples/10_entities/README.md) pair
source, README, and executable test. The focused command
`mise exec -- mix test test/examples/10_entities --include example --seed 0`
passes four peer cases with zero failures. Tests check exact claims, Agent
count/revision, Ref identity, old source exit, and empty worker Agent pools at
cleanup. The focused entity command passes 13 tests with zero failures: nine
unit contracts and four peer examples, seed 0. Its log is
`/tmp/jido-cluster-s7-focused.log`.

### Bounded activation measurement

The reproducible [benchmark](../../../bench/entity_activation.exs) runs eight
sequential first activations on one local BEAM node. It uses Mnesia RAM tables
for the scope journal and Agent checkpoints, with one host of capacity eight.
`mise exec -- mix run bench/entity_activation.exs` reported eight active claims,
198.878 ms total, 21.276 ms median, 47.122 ms maximum, and a 17,756-byte
journal record against the 98,304-byte limit. These figures select the bounded
scope for this implementation; they do not establish production throughput,
large-cardinality behavior, or partition safety.

### Proof limits

The examples use connected native peers and shared Mnesia. They do not use a
real external host provider. This slice adds no replica synchronization,
follower reads, live legacy migration, or durable Signal acknowledgement.
Control-runtime loss retains the prior uncertainty rules. The eight-entity
limit is a small admitted scope, not a general entity-service scale claim.

### Final local checks

`mise exec -- mix test.all` passes 384 tests with seed 0 and no failures
(`/tmp/jido-cluster-s7-final-all.log`). `mise exec -- mix quality` passes with
189 documented and specified modules, 100% Doctor coverage, and no Credo
issues (`/tmp/jido-cluster-s7-quality.log`). Production compilation with
warnings as errors and `mix docs` pass
(`/tmp/jido-cluster-s7-prod.log`, `/tmp/jido-cluster-s7-docs-final.log`). The
new example and design Markdown links resolve locally, and `git diff --check`
passes.

The prepared Linux worker image built from the final V3 source is
`sha256:7bec0388115a6a38580569959edada31c3c2231ce739f98457f8dee5275a64d3`.
The explicit Docker backend command passes five cases
(`/tmp/jido-cluster-s7-docker-backend.log`), and the provider example command
passes nine cases, including both cumulative Core modes
(`/tmp/jido-cluster-s7-docker-examples.log`). These are S6 regression checks
after the S7 service changes; they do not make the entity examples Docker
examples. No Cluster-labelled container remains after the runs. The dedicated
Docker CI job has no remote result because this worktree is unpushed.

S1–S7 local implementation and acceptance are complete for the stated bounds.
Design review status is still `Pending approval`. No commit, push, or sibling
source edit is part of this result.
