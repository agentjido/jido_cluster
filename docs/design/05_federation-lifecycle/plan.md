# S5 — Bindings through movement and restart

Status: implemented and verified; review pending approval. Written on
2026-09-15. The implementation, required examples, and static cumulative proof
pass the final package checkpoint below. Earlier
checkpoints describe the work at that time. See [scope and dependencies](README.md).

## Outcome

Keep logical subscriptions attached to the correct Agent incarnation through
drain, bridge restart, and deployment stop. Report the best-effort delivery gap.

## Implementation steps

1. Write transition tests for stale attachment, uncertain detach, and bridge loss.
2. Journal each binding's logical identity, desired location revision, and pending
   lifecycle step. Keep transient PIDs out of records.
3. Integrate binding transitions into deployment operations: record intent, retire
   source attachment/Agent, establish target readiness, then attach target binding.
4. Publish settled location/binding status only after required steps complete.
   Reject requests for superseded location or host incarnations.
5. Reconstruct declared bindings after bridge or coordinator restart by checking
   live location and journal revision before attachment.
6. Reference-count shared transport use. Remove only this deployment's bindings and
   mirrors during stop; retain resources still used by another deployment.
7. Add moved-subscriber and interrupted-bridge examples.

## Contracts and lifecycle

Use binding ID, core Ref, channel, path, host incarnation, and location revision
as the attachment contract. Repeated attachment to the same current target is
idempotent. A different target with an old revision is rejected.

Start with topology-declared subscriptions. Defer imperative subscription creation
unless its persistence and request-identity contract is added explicitly. Report
Agent readiness and federation health separately. Required missing bindings mark
the deployment degraded or incomplete; transport failure alone does not prove
Agent failure or revoke placement authority.

## Failure handling

- Uncertain detach: retain operation uncertainty rather than claim settled move.
- Target attach fails: retain target placement evidence and expose incomplete binding.
- Bridge restart: rebuild bindings, but do not replay lost memory events.
- Source unreachable: follow placement uncertainty rules; no forced replacement.

## Tests and completion

Move a subscriber and verify later events reach the target. Inject old attachment
requests and verify rejection. Restart bridges between each transition step.
Stop one of two deployments using shared transport and retain the other. Observe
bounded queue behavior and reported loss during disconnect.

Done when bindings follow accepted placement, unrelated resources survive cleanup,
and tests prove the documented loss and uncertainty boundaries.

Write the unit contracts first, then local peer tests, then the tagged living
example. Run relevant package format, compile, quality, and test checks. Record
actual results and evidence links here before marking this slice complete.

## Example-based acceptance plan

Status: 08_01–08_04 and the static cumulative example are implemented. Follow the
[shared example test method](../00_architecture/example-testing.md).

Proposed group: `examples/08_federation_lifecycle/`, mirrored under
`test/examples/08_federation_lifecycle/`. These numbers extend the existing 01–03 groups;
confirm they remain free before implementation. Keep scenario IDs stable once added.

### Setup

Use a publishing peer, source and target workers, and two deployments sharing
transport. One topology declares a listening Agent. Retain its Ref and logical
binding ID while recording location revisions.

### Scenarios

| Proposed example | Actions | Required observations |
| --- | --- | --- |
| `08_01_subscription_move` | Deliver event A, drain the subscriber host, wait for settled binding readiness, then deliver event B. | The same Ref retains A and receives B on the target. Source attachment is retired. An attachment request with the old revision is rejected. |
| `08_02_bridge_restart` | Interrupt a bridge after publication acceptance, restart it, await reconstructed bindings, then publish a fresh event. | Loss or unknown delivery is visible for the interrupted event. The fresh event arrives after readiness. No replay of lost memory events is promised. |
| `08_03_shared_cleanup` | Stop one deployment while both use the transport; publish to the remaining deployment. | Only stopped bindings/mirrors are removed. The shared transport and remaining subscriber continue to work. |
| `08_04_uncertain_attachment` | Pause or fail target attachment during drain, then explicitly reconcile. | Agent location can be known while binding completion remains incomplete. The operation does not report settled federation readiness prematurely. |

### Evidence and failure control

Check actual subscriber state and public binding status together. During a
movement gap, accept documented loss; do not assert continuous delivery. Use
host-incarnation and revision fixtures to send stale requests. Bridge failure
must not change capacity claims or authorize Agent replacement.

### Promotion record

For each scenario, add links to its source, README, and executable test. Record
the command, seed, backend, result, and cleanup result. Map every README guarantee
to an assertion. A fake-only result cannot prove an external backend contract.
Keep this slice incomplete until its required examples and lower-level contracts
pass; record unavailable cases explicitly.

## Cross-slice refinements

Use [the lifecycle/readiness contracts](../00_architecture/lifecycle-contracts.md).
A historically completed deploy operation stays completed if a bridge later fails;
current deployment readiness and federation health describe the new condition.
Test loss of required bindings separately from transport-only degradation.

Extend restart scenarios to include actual worker cleanup and reactivation, not
only a surviving Agent with a restarted bridge. Reattach only to the accepted
current location and incarnation. Unknown detach blocks conflicting binding work,
not unrelated operations on disjoint resources.

Build and pass the static cumulative system example before promoting this slice.
It combines two deployments, federation, partial drain, coordinator restart,
uncertain placement, independent progress, and final cleanup. Its specification is
in the shared lifecycle document; avoid a second copy here.

## Final build refinements

Extend the cumulative test with delayed directory visibility after target startup.
Verify that binding reconciliation waits for the accepted incarnation and does not
start another subscriber. Record structured phase/reason evidence for interrupted
cleanup, while keeping payloads out of logs.

## Decisions and limits

Keep this slice on the S4 best-effort mode. Durable event delivery and application
acknowledgements require a separate protocol. Choose the exact degraded-state
representation before adding public status fields.

## Mirror generation primitive

Implemented on 2026-09-16. This increment supplies a cleanup prerequisite for
movement and bridge reconstruction. It does not remove the static movement guard
or add automatic replacement to the deployment runtime.

Each activation retains one resource record per host and channel. Its revision
starts at zero and is bounded to `9_007_199_254_740_991`. The phases are
`unstarted`, `active`, `closing`, and `settled`. The record also retains the exact
mirror PID while that process owns cleanup. These records remain VM-local; they
are not binding location records in the journal. Replacing a revision updates
the same record, within the existing 256-resource limit.

Only the deployment owner can close a resource revision or prepare its immediate
successor. Repeating preparation for the current revision is idempotent and does
not reopen a closed revision. Closing an unused revision records settlement
atomically and rejects delayed creation at that revision. Preparing the next
revision requires prior settlement. Claim, authorization, and settlement carry
the exact revision. Authorization also checks the actual mirror caller PID across
nodes; an RPC relay PID cannot act as the mirror.

`Mirror.stop_generation/5` requires a closed revision. It stops only the retained
mirror PID and then checks settlement for that same revision. An old stop request
cannot terminate the replacement found under the stable Registry key. Missing
processes and Registry entries do not supply cleanup receipts.

The mirror now owns a dedicated export task supervisor beside the bridge. A
bridge crash leaves that supervisor available for orderly mirror cleanup. A
mirror can then confirm all owned component exits and settle its record. Abrupt
mirror loss or abrupt export-supervisor loss still retains uncertainty. This
change does not alter Agent ownership or create Agent replacement authority.

After settlement, a new mirror can attach to the same ready Agent. Its logical
binding ID is unchanged; its Bus subscription IDs are new. No volatile event is
replayed. The interrupted export test records local acceptance and uncertain
remote completion; it does not claim remote delivery.

### Requirements and evidence

- CL-BINDING-REQ-001: When a resource revision is closed, Activation shall reject new mirror control at that revision.
- CL-BINDING-REQ-002: If prior resource cleanup is unconfirmed, then Activation shall reject preparation of the next revision.
- CL-BINDING-REQ-003: When a stale stop request addresses a replaced revision, Mirror shall retain the replacement process.
- CL-BINDING-REQ-004: When an unused resource revision is closed, Activation shall reject delayed creation at that revision.
- CL-BINDING-REQ-005: When a bridge exits, Mirror shall require confirmed export-task cleanup before it settles the resource revision.
- CL-BINDING-REQ-006: When a resource revision is replaced, Activation shall retain one record for that host and channel.

| Requirement | Current evidence |
| --- | --- |
| 001 | Local and peer generation tests reject attachment and publisher lookup after closure. The peer test rejects a caller that tries to act as the deployment owner or mirror. |
| 002 | Activation and generation tests reject preparation during active or uncertain cleanup; abrupt mirror loss remains uncertain. |
| 003 | Local and peer tests send a stale stop after replacement, then publish through the unchanged replacement PID. |
| 004 | Activation test closes 11 unused revisions and rejects each delayed claim. |
| 005 | The generation test interrupts a bridge with one held export task and checks the task's exit before replacement. Existing mirror tests retain uncertainty after abrupt task-supervisor loss. |
| 006 | The repeated unused-revision test observes one retained host/channel key. |

Evidence files:

- [Activation tests](../../../test/jido_cluster/activation_test.exs)
- [Local generation tests](../../../test/jido_cluster/federation/generation_test.exs)
- [Peer generation test](../../../test/jido_cluster/distributed/federation_generation_test.exs)
- [Mirror cleanup tests](../../../test/jido_cluster/federation/mirror_test.exs)

The focused Bridge, Mirror, and generation run passes 26 tests with seed 0. The
new two-node generation run passes one test with seed 0 and checked Agent,
component, owner, Core, and peer cleanup. It uses a bounded test owner for this
primitive. It does not claim managed deployment recovery or placement movement.

The complete `mise exec -- mix test.all` repeat passes 278 tests with seed 0 in
90.6 seconds, including the real Bedrock suite. `mise exec -- mix quality` passes
format, compilation, strict Credo, and Doctor. The first full run exposed a
Bedrock test cleanup race; the fixture now requires the exact placeholder exit
receipt even if it exits before its stop call. The passing repeat includes that
fix. No sibling package source was changed.

The next increment below adds the initial journal protocol. Placement movement
and bridge-only repair still need exact-owner resource changes through that
protocol. Keep uncertain detach visible and preserve independent progress. The
required examples and cumulative proof remain pending.

## Journaled binding intent

Implemented initial setup, stop, and full activation recovery on 2026-09-16.
`Federation.Intent` stores portable logical IDs, Ref IDs, root paths, channel keys,
accepted host names and incarnations, and required flags. The enclosing deployment
supplies the Ref namespace and topology identity. Each record has an activation
ID, a binding revision, per-host/channel mirror revisions, and a pending phase.
No PID, subscription ID, payload, or event cursor enters this record.

The first revision is zero. A confirmed full activation replacement increases the
binding revision, retains logical IDs, and resets new activation mirror revisions
to zero. Mirror resource revisions and binding revisions are separate: the former
protect host-local process cleanup; the latter identify accepted binding intent.
Both have the finite integer bound defined above. The schema inherits the DSL's
64-binding bound and permits at most 256 mirror records. Aggregate byte bounds
still apply; these separate count limits are not a combined scale guarantee.

The initial acceptance write records `planned` before deployment effects. After
Core readiness and a fresh guard check, the service records confirmed binding
host incarnations and `attaching` before mirror creation. Required attachment
receipts precede the `ready` write, which precedes deployment completion. Optional
missing bindings remain visible in live status. `ready` records required setup
completion, not current connectivity or event consumption.

Stop records `detaching` with stopped intent before cleanup. Only confirmed
deployment cleanup records `stopped`. Full activation recovery retains the old
record until cleanup is confirmed, then writes the replacement intent before
starting a replacement Scheduler. Setup callbacks carry the exact expected binding
revision from the accepted Scheduler guard. Stale activation or revision callbacks, changed placements,
changed host incarnations, and callbacks after stopped intent are rejected.

`Journal.Snapshot` validates the binding record against the stored declaration and
accepted placement. Version-1 snapshots that omit the field restore declarations
as `planned` with no invented host-incarnation receipt. Normal running-intent
recovery still requires prior activation cleanup. Explicit null binding intent is
valid only for a topology with no channels. This migration does not infer live
attachments from old completed operations.

`status/2` exposes `binding_intent` beside live `binding_readiness`. A bridge loss
does not erase the recorded setup or rewrite historical operation completion.
This increment supports full activation recovery; it does not yet repair a bridge
while keeping its Agent alive or move a subscriber between hosts.

### Requirements and evidence

- CL-BINDING-REQ-007: Before mirror creation, the deployment service shall confirm the attachment intent journal write.
- CL-BINDING-REQ-008: Before deployment completion, the deployment service shall confirm the required binding completion journal write.
- CL-BINDING-REQ-009: When deployment stop is accepted, the deployment service shall record pending detach before cleanup.
- CL-BINDING-REQ-010: When full activation recovery replaces a binding, the deployment service shall retain its logical ID and increase its binding revision.
- CL-BINDING-REQ-011: If a binding callback addresses a prior activation, a different binding revision, or stopped intent, then the deployment service shall reject it.
- CL-BINDING-REQ-012: When a legacy snapshot lacks binding intent, the snapshot reader shall restore declarations without claiming confirmed attachment.
- CL-BINDING-REQ-013: If recorded binding identity differs from the declaration or accepted placement, then the snapshot reader shall reject the record.

| Requirement | Current evidence |
| --- | --- |
| 007 | A held write observes a ready Core Agent and no mirror. A committed write with a lost reply starts no mirror; explicit recovery retains identity and advances the revision. |
| 008 | A held completion write observes ready bindings while the deployment remains accepted. A lost reply blocks publication and deployment completion until recovery. |
| 009 | A held detach write retains the live mirror. Confirmed cleanup records stopped; a later full service restart creates no Agent. |
| 010 | Real Bedrock and Mnesia tests stop the service and Core, check actual Agent and mirror exits, recover, retain committed Agent events, and publish a new event. Bedrock also restarts its Repo. |
| 011 | Journal tests send stale activation, changed revision, and post-stop callbacks and check rejection. Pure intent tests reject changed host-incarnation evidence. |
| 012 | A JSON snapshot test removes the new field and observes planned intent with no incarnation receipt. |
| 013 | Pure validation and snapshot tests reject altered Ref, path, host, phase, revision, activation, and nonportable data. |

Evidence: [pure intent tests](../../../test/jido_cluster/federation/intent_test.exs),
[journal boundary tests](../../../test/jido_cluster/federation/journal_test.exs),
[snapshot tests](../../../test/jido_cluster/journal_snapshot_test.exs),
[real Bedrock test](../../../test/jido_cluster/distributed/federation_journal_test.exs),
and [real Mnesia test](../../../test/jido_cluster/journal_mnesia_test.exs).

The backend contract also deploys eight real Agents with eight channels and
64 required bindings. It checks all live bindings, the actual encoded aggregate
against the 65,536-byte admission limit, and final Agent/mirror/component cleanup.
The focused Bedrock run measured 29,445 bytes. This single-deployment fixture does
not establish the maximum simultaneous deployment count. The older S3 fixture
measures request bindings, not federation bindings.

Verification: `mise exec -- mix quality` passes with 116 documented modules and
complete spec coverage. The final `mise exec -- mix test.all` run passes 287 tests
with seed 0 in 92.6 seconds. It includes the exact expected-revision callback
check, both real backend binding contracts, and the 64-live-binding fixture.
S5 movement, bridge-only repair, shared cleanup proof, four living examples, and
the static cumulative example remain pending.


## Journaled subscriber movement

Implemented managed instance drain integration on 2026-09-16. Direct legacy
Scheduler planning retains its restriction. This increment does not complete S5.

Drain acceptance now records desired placement and binding revision together with
`federation_transition`. The transition retains prior ready intent, source
placement, and every retained host/channel resource revision. Its phases are
`retiring` and `retired`. The record is portable, bounded to 256 resource keys,
and validated against declarations, inventory, and consecutive revisions.
Historical resource keys remain until activation cleanup; returning to a prior
host uses the next revision rather than revision zero. Exhaustion rejects the
candidate before effects. Existing aggregate byte limits still apply.

The exact Owner operation task closes each retained revision, confirms mirror
cleanup, and records `retired` before Core movement. It then prepares target
mirror revisions. Core establishes target readiness before the existing
attachment-intent write, mirror setup, and required-binding completion write.
Completion clears the transition. Source claims remain until the drain confirms
Core and required binding readiness and releases the source reservation.

This implementation replaces all channel mirrors in the moving deployment.
It permits a best-effort delivery gap across those channels. Other deployments
have separate mirrors. It does not replay events. Public deployment status
exposes the pending transition beside recorded intent and live readiness.

Unknown retirement writes stop dependent Core movement. An unknown attaching
write can leave a ready target Agent without a mirror. Explicit full recovery
confirms old activation cleanup, preserves committed Agent state through the
separate persistence adapter, and reconstructs required bindings. Uncertainty
retains source and target claims. A missing process is not a cleanup receipt.

### Requirements and evidence

- CL-BINDING-REQ-014: Before source binding cleanup, the deployment service shall confirm the desired placement and prior retirement intent journal write.
- CL-BINDING-REQ-015: Before Core movement, the operation task shall confirm exact source mirror cleanup and its journal receipt.
- CL-BINDING-REQ-016: When a move returns to a previously used host, the deployment Owner shall prepare a successor mirror revision after prior settlement.
- CL-BINDING-REQ-017: Before a managed drain completes, the deployment service shall confirm the required binding receipt for the accepted target.
- CL-BINDING-REQ-018: If a movement journal reply is unknown, then the deployment service shall retain the complete transition reservation until explicit recovery.
- CL-BINDING-REQ-019: If a resource change caller is not the Owner's current operation task, then the deployment Owner shall reject the change.

| Requirement | Current evidence |
| --- | --- |
| 014 | Lost retiring-write reply leaves the original Agent and mirror alive, with no target Agent. |
| 015 | Lost retired-write reply leaves the original Agent alive, confirms source mirror exit, and starts no target Agent. |
| 016 | Peer test moves out and back, checks revision 1 on the restored source mirror, and rejects a stale revision-0 stop. Pure transition tests cover retained history. |
| 017 | Peer tests and 08_01 retain the Ref and logical binding ID, advance binding revision, preserve committed events, and deliver a fresh event at the target. |
| 018 | Lost retiring, retired, and attaching replies retain both claims. Explicit recovery completes the original request and preserves committed state. The attaching case observes a target Agent with no mirror. |
| 019 | The movement peer test submits a foreign caller's resource closure and checks rejection. |

Evidence: [transition validation](../../../test/jido_cluster/federation/transition_test.exs),
[movement peer tests](../../../test/jido_cluster/distributed/federation_movement_test.exs),
and [managed deployment tests](../../../test/jido_cluster/distributed/federation_deployment_test.exs).
The focused transition and movement run passes six tests with seed 0. The earlier
movement, managed deployment, and shared drain run passes 11 tests with seed 0.

[08_01 Subscription move](../../../examples/08_federation_lifecycle/08_01_subscription_move/README.md)
has [source](../../../examples/08_federation_lifecycle/08_01_subscription_move/subscriber.ex)
and a [mirrored test](../../../test/examples/08_federation_lifecycle/08_01_subscription_move/subscriber_test.exs).
Its focused run passes with seed 0, a real Bedrock journal, and shared Mnesia
Agent storage. It checks old and current mirror components, Agents, claims,
Core, journal, and peer cleanup. Bedrock has one peer and relaxed durability;
this is not a replica or machine-failure proof.

Bridge-only repair, shared cleanup proof, the remaining three living examples,
and the static cumulative example remain pending. The cumulative proof must
include delayed target visibility, independent progress, and actual worker
cleanup and restart. General placement telemetry remains; additional structured
federation transition telemetry still needs review.


Final movement checkpoint: `mise exec -- mix quality` passes with 123 documented
modules and complete specification coverage. `mise exec -- mix test.all` passes
294 tests with seed 0 in 101.9 seconds. Production compilation with
warnings-as-errors and `mix docs` pass. Catalog checks cover 29 stable source/test
folder pairs and changed local links. `git diff --check` passes. The real Bedrock
64-binding fixture measures 29,474 journal bytes; the S3 aggregate measures
53,110 bytes. No commit or sibling source change was made.


## Explicit bridge and connection repair

Implemented on 2026-09-16 after the movement checkpoint. When journal and Agent
placement are ready, `reconcile/1` checks current federation observations and
runs one bounded repair pass. Healthy declarations cause no mirror replacement
or journal write. A failed bridge, missing required binding, or degraded
connection causes a transition at the same accepted placement.

The service records the next binding intent and source retirement manifest
before cleanup. The exact Owner operation task retires prior mirrors, confirms
the journal receipt, prepares successor revisions, and reconstructs declared
bindings. The repair operation checks the existing Controller, placements, and
Agent PIDs. It makes no Core creation, movement, reconciliation, or stop call.
The same activation, Ref, logical binding ID, and host incarnation remain.
Capacity claims and historical deployment operation records remain unchanged.

`binding_repair: :running` reports the active service repair attempt. A pending
transition and structured `reason` report unresolved work. Stop and drain requests for
that deployment return busy errors during active repair work; independent deployment requests can
proceed. A failed or interrupted attempt releases its execution slot without
releasing capacity. Exact resource cleanup still controls subsequent repair.
Explicit stop continues to use the full activation cleanup contract.

The runtime emits `[:jido, :cluster, :federation, :retirement, :start | :stop |
:exception]` telemetry through a span. Metadata identifies namespace, topology,
activation, binding revision, phase, and result reason. It contains no Signal
payload. The start event precedes resource closure; retired completion follows
its journal receipt. The pending transition remains the portable phase record.

This is explicit reconstruction, not an automatic reconnect loop. One repair
pass can replace every channel mirror in an affected deployment, with a
best-effort delivery gap. It does not replay volatile events. Unknown journal
outcomes retain the existing full recovery requirement; this same-activation
repair path does not bypass journal reload or cleanup evidence. An abrupt mirror
exit still lacks a cleanup receipt and cannot authorize reconstruction.

### Requirements and evidence

- CL-BINDING-REQ-020: When explicit reconciliation repairs a failed bridge with ready placement, the Scheduler shall retain the accepted Agent PID.
- CL-BINDING-REQ-021: When bridge repair completes, the deployment service shall retain capacity claims and historical operation completion.
- CL-BINDING-REQ-022: While one deployment waits for binding retirement, the instance service shall permit admissible independent deployment work.
- CL-BINDING-REQ-023: When explicit reconciliation observes healthy bindings and transport, the service shall retain existing mirrors and journal bytes.
- CL-BINDING-REQ-024: When mirror retirement starts or finishes, the federation runtime shall emit correlated phase telemetry without Signal payloads.
- CL-BINDING-REQ-025: While binding repair or its retirement transition is pending, the deployment service shall reject publication as not ready.

| Requirement | Evidence |
| --- | --- |
| 020 | Local repair tests retain the exact Agent PID and events. The peer test repairs a failed connection and delivers a fresh event to the same remote PID. |
| 021 | Local, peer, and example tests compare complete claim sets and historical operation records before and after repair. |
| 022 | A public retirement-event barrier holds the repair task. Another deployment starts, receives an event, and stops while the first Agent and claims remain unchanged. |
| 023 | A second reconciliation retains the mirror PID and exact adapter write history. |
| 024 | The independent-work test uses the start event as its explicit barrier. The same span records the final phase and reason. |
| 025 | The independent-work test rejects publication for the repairing deployment while a separate deployment receives its own event. |

[Local repair tests](../../../test/jido_cluster/federation/repair_test.exs) also
hold the retired journal receipt and prove that no replacement mirror starts
before release. The [peer deployment test](../../../test/jido_cluster/distributed/federation_deployment_test.exs)
uses native transport for loss observation, reconnection, and fresh delivery.
The focused local and peer run passes six tests with seed 0.

[08_02 Bridge restart](../../../examples/08_federation_lifecycle/08_02_bridge_restart/README.md)
now has [source](../../../examples/08_federation_lifecycle/08_02_bridge_restart/subscriber.ex)
and a [mirrored test](../../../test/examples/08_federation_lifecycle/08_02_bridge_restart/bridge_restart_test.exs).
It holds one export at a controlled transport boundary, observes local acceptance
and pending work, interrupts the bridge, and checks exact export-task and mirror
cleanup. Repair uses the real channel declaration and native connections. A fresh
event reaches the unchanged Agent; the held event is not replayed. The fixture
uses a real Bedrock journal and checks old/current components, Agent, claims,
transport fixture, Core, journal, and peer cleanup. The two S5 examples pass their
focused run with seed 0.

Shared cleanup, the uncertain attachment example, and the static cumulative
system example remain required. The cumulative test must still prove delayed
location visibility, actual worker cleanup/restart, independent progress during
uncertainty, and ordered recovery. S5 remains incomplete.


Final repair checkpoint: `mise exec -- mix quality` passes with 128 documented
modules and complete specification coverage. The final `mise exec -- mix test.all`
run passes 298 tests with seed 0 in 105.1 seconds, including rejection of
publication while repair is pending. Catalog checks cover 30 stable source/test
folder pairs and changed links. The real Bedrock 64-binding fixture measures
29,572 journal bytes; the S3 aggregate measures 53,110 bytes and 25 CAS writes in
45,791 microseconds. These measurements are fixture evidence, not capacity or
throughput guarantees. S5 is not complete. No commit or sibling source edit was made.


## Static cumulative proof and final failure audit

Implemented on 2026-09-16. All four S5 living examples now have source, README,
and matching tests. The final two use a real Bedrock journal and shared Mnesia
Agent storage:

- [08_03 Shared cleanup](../../../examples/08_federation_lifecycle/08_03_shared_cleanup/README.md)
  stops one of two deployments on the same host. Every stopped component exits.
  The other Agent, mirrors, bindings, and claims retain their exact identities,
  and a fresh event arrives over the retained native BEAM connection.
- [08_04 Uncertain attachment](../../../examples/08_federation_lifecycle/08_04_uncertain_attachment/README.md)
  loses the reply after Bedrock commits target attachment intent. Core reports a
  ready target Agent, but no target mirror exists. The original drain remains
  incomplete and both claims remain. Full recovery checks old and intermediate
  Agent cleanup, retains the Ref and committed state, and completes the original
  request before fresh delivery.

Shared transport decision: the BEAM VM owns native node connections. Deployment
cleanup never disconnects them. Each deployment owns its own bounded senders,
mirrors, and bindings. There is no shared application sender to reference-count.
The shared-cleanup example directly proves the required ownership result.

[11_01 Deployment lifecycle](../../../examples/11_system/11_01_deployment_lifecycle/README.md)
combines the S1–S5 contracts in both managed and attached modes. Four peers host
one coordinator, two shared workers, and one independent worker. The test stops
an earlier deployment, starts two subscribers, delays target Ref visibility,
interrupts a drain after its first move, and restarts the coordinator. It checks
actual Agent exits before recovery. The original drain token, committed events,
and stopped intent survive. A later live-source disconnect retains source and
target claims while independent work starts and receives an event. Reconnection
and explicit recovery permit fresh delivery, followed by checked cleanup.

The visibility barrier uses public Core lifecycle telemetry. It holds a new
Agent before public Ref resolution becomes ready. Core currently implements
this through its Registry and public lookup APIs; Cluster does not require a
separate directory process. Cluster lookup remains pending, the target mirror
is absent, and another reconcile request is busy until the original work resumes.

The cumulative test found an empty-allocation recovery gap. Host confirmation
now handles `reconciliation_required` with an exact empty-set reconciliation only
when the direct allocation has no claims, its incarnation/scope/capacity match,
and every journal claim on that host is an unconfirmed new reservation. Bound,
active, or uncertain claims still require normal recovery. Host reconciliation
checks owner, scope, incarnation, and the empty set again before rebinding.
The focused attached-Core regression retains the same host incarnation and
stopped operation while new independent work uses the freed capacity.

### Final requirements and evidence

- CL-BINDING-REQ-026: If a mirror exits without a cleanup receipt, then repeated deployment repair shall retain its uncertain transition and capacity claims.
- CL-BINDING-REQ-027: When one deployment stops, federation cleanup shall retain another deployment's live components and shared native connection.
- CL-BINDING-REQ-028: While target Ref visibility is pending, federation setup shall retain pending attachment without starting another subscriber.

| Requirement or failure boundary | Evidence |
| --- | --- |
| 026 | The [managed repair test](../../../test/jido_cluster/federation/repair_test.exs) kills a mirror, performs two repairs, and checks the same Agent, claims, historical request, structured reason, and absent replacement. Stop remains uncertain. Test teardown checks actual Agent exit without claiming durable cleanup settlement. |
| 027 | [Shared cleanup test](../../../test/examples/08_federation_lifecycle/08_03_shared_cleanup/shared_cleanup_test.exs) checks exact process identities and fresh native delivery. |
| 028 | [Cumulative test](../../../test/examples/11_system/11_01_deployment_lifecycle/deployment_lifecycle_test.exs) checks one pending Agent, failed Core resolution, pending Cluster lookup, no target mirror, and a busy second reconcile. |
| Retiring receipt | A held journal reply permits a source bridge failure; exact mirror cleanup still precedes movement. |
| Retired and attaching receipts | No bridge exists on source, target, or control while these replies are held. The target bridge starts only after attachment intent is confirmed. |
| Ready receipt | The target bridge exits after its binding receipt is written but before the reply arrives. Current binding readiness reports the loss. Explicit repair restores delivery to the same target Agent; historical drain completion remains unchanged. |
| Unknown transition writes | Existing tests lose retiring, retired, and attaching replies. No dependent effects bypass the journal barrier; full recovery retains both claims until settlement. |
| Empty host after owner loss | The [recovery regression](../../../test/jido_cluster/recovery_test.exs) and both cumulative modes prove admission after checked empty-allocation reconciliation. Existing partition tests retain exact claim and ownership checks. |

The four new held-receipt cases are in the
[movement peer tests](../../../test/jido_cluster/distributed/federation_movement_test.exs).
The focused movement run passes eight tests with seed 0. The managed repair run
passes four tests. The recovery, host control, host partition, and cumulative run
passes 18 tests. The S5 example run passes all four scenarios. These runs use
checked process/peer cleanup; real Bedrock evidence comes from the living examples
and backend tests, not the controlled journal adapter in boundary tests.

Completion means a confirmed binding receipt at the accepted location. Live
readiness is a later observation and can degrade immediately after that receipt.
Requirement 017 now states this boundary explicitly. Durable replay, continuous
delivery, VM-loss cleanup proof, and forced replacement remain outside S5.

Final package checkpoint: `mise exec -- mix quality` passes, with 141 modules
and complete documentation and specification coverage. `mise exec -- mix test.all`
passes 308 tests with seed 0 in 127.5 seconds. Production compilation with
warnings-as-errors and `mix docs` pass. Catalog checks cover 33 stable source/test
pairs, inherited or direct example tags, and local Markdown links. `git diff --check`
passes. The real Bedrock live-binding fixture measures 29,474 bytes for 64 bindings;
the S3 aggregate measures 53,110 bytes and 25 CAS writes in 48,508 microseconds.
These measurements describe the fixtures, not throughput or capacity guarantees.

S5 acceptance is complete for the stated best-effort contract. Review remains
Pending approval. Continue with S6 provider contracts, Docker, and the provider
cumulative variant. No commit or sibling source change was made.
