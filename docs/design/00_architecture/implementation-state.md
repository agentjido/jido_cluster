# Implementation state

> Current scope after legacy removal: applications use named `Jido.Cluster`
> instances and `Jido.Cluster.Entity`. The standalone manager, standalone
> Scheduler, offline checkpoint importer, example groups 01–03, and V2 archive
> have been removed. `Deployment` is private runtime code under the named scope.
> Earlier statements and test counts below describe historical checkpoints.


Status: S1–S7 local implementation and acceptance pass for their stated bounds.
Review remains pending approval. Both cumulative provider modes pass on the
local Docker Engine. S7 has bounded entity runtime, peer examples, recovery and
migration tests, and a local size measurement. See the final S7 section for
current results; older sections retain historical checkpoints as written.

## Current persistence integration — 2026-09-16

Cluster journal byte I/O now uses `Jido.Persistence.Store` from local core.
Core owns adapter validation, fault containment, CAS result classification,
and storage telemetry. Cluster owns journal keys, JSON, bounds, revisions,
write identity, and recovery decisions. The journal key and record format are
unchanged. Core `Jido.Persistence.Mnesia` replaces the duplicate Cluster adapter.

The [S3 integration record](../03_journal-and-recovery/plan.md#core-store-integration--2026-09-16)
describes the boundary tests and verification. Current results are 343 passing
Cluster tests, 19 selected core persistence tests, and 14 real Docker tests.
Earlier suite counts and adapter ownership below are historical.

## Current runtime consolidation — 2026-09-16

The named Cluster instance is the public control path for Topologies and entities.
The standalone keyed manager, its configuration and membership processes, the
standalone Scheduler API, offline entity checkpoint import, and the V2 archive
have been removed. Example groups 01–03 and the import example are retired;
remaining group numbers stay stable. Shared definitions needed by current tests
now live under `test/support`.

The retained placement worker is private `Jido.Cluster.Deployment`. It requires
a scope reservation and activation guard. Recovery uses its registration lookup
and waits for the previous worker to exit before starting a replacement. Fixture
supervisors belong to test support and the prepared Docker worker, not the SDK.
The shared journal format, Agent Ref mapping, and core persistence keys remain
unchanged. The removed entity import requirement CL-ENTITY-REQ-005 is retired.

The [recovery guide](../../../guides/recovery.md) now maps each durable record to
its owner, key identity, and configured backend. The Cluster journal does not
implicitly configure core persistence. Core Topology targets and Agent checkpoints
remain separate from the scope journal, even when they share a backend.

Verification of this revision:

- `mix test.all`: 341 tests, zero failures, seed 0 (213.1 seconds).
- Real Docker backend: five tests, zero failures.
- Real Docker examples: nine tests, zero failures, including managed and attached
  cumulative recovery. No Cluster-labelled test container remains.
- `mix quality` and `mix docs`: pass, including full Doctor coverage.
- Production warnings-as-errors compilation: pass in the prepared Docker image.
- 804 local documentation links resolve; `git diff --check` passes.

The worker image is
`sha256:1a159d54311fce5ec38b0004e516687952743250b7595b35b84900be73a02dec`.
Local logs are `/tmp/cluster-cut-all-final.log`,
`/tmp/cluster-cut-docker-final.log`, `/tmp/cluster-cut-docker-examples-final.log`,
`/tmp/cluster-cut-quality.log`, and `/tmp/cluster-cut-docs.log`.
Earlier counts and legacy migration evidence below are historical. No commit,
push, or sibling source change was made during this consolidation.

## Completed increments

- Named managed and attached instances, configuration validation, the deployment
  facade, request tokens, operation lookup/await, Ref routing, and orderly cleanup.
- Three two-node deployment examples under `examples/04_deployment`, mirrored by
  `:example` tests. Existing groups 01–03 remain active regression tests.
- Early entity mapping probe. Core identity survives exact-node placement; legacy
  keyed IDs differ and need an explicit migration contract.
- Shared initial admission, canonical pool aliases, host claim confirmation,
  exact reservation application, guarded release, and a pure claim model.
- Scope-wide drain reservation and execution. A peer test moves two deployments
  from one shared source and checks state, Ref identity, claims, and cleanup.
- Guard process restart retention, exact reconciliation, lost operation response
  handling, and correct readiness for stopped intent with uncertain cleanup.
- Correlated operation and movement telemetry, explicit host re-enable, and
  independent progress while a drain retains uncertain source and target claims.
- Five shared-capacity examples under `examples/05_shared_capacity`, with
  independent peer callers, real core activations, and checked cleanup.
- Shared guard lifetime and explicit fixed allocation partitions. Different
  scopes can share a core with separate limits; duplicate Ref claims are rejected.
- Direct stale-release and stale-budget peer tests, structured host refusal
  reasons, and busy-claim checks for incoming placement and pending stop cleanup.
- Bounded S7 domain-key mapping to one core Topology per entity. Concurrent first
  requests share the scope admission path. Native peer examples cover first
  calls, movement, mixed capacity, and offline old-checkpoint import.

- S3 storage contracts: versioned JSON journal, exact-byte and token CAS,
  blocked handles after unknown writes, reload discovery, and delayed-write tests.
- Portable topology definitions and input through explicit stable registry IDs.
- Real Bedrock record/repository-restart test and the same contract with Mnesia.
- Request retention epochs, count limits, explicit saturation and expiry, and
  stopped-intent retention through the memory service facade.
- Complete portable aggregate codec, stable request fingerprints, full drain
  step intent, and record validation against the configured inventory.
- Real Bedrock and Mnesia writes of a bounded aggregate with 16 deployments,
  32 claims, 64 request bindings, and 16 pending drain steps; repository restart retains it.
- Service journal writes before task start, host confirmation, result reporting,
  and epoch advance. Explicit registry, portable fingerprints, and byte checks
  now apply to durable service requests.
- Stopped-intent service restart, lost-write and CAS-conflict blocking, persistent
  expiry, and conservative possible claims after unknown completion.
- Actual Bedrock and Mnesia deploy/work/stop/service-restart cycles, plus the
  two-deployment peer drain in journal mode.
- Journaled activation identity that survives request expiry, with exact-owner
  cleanup evidence retained outside the named service lifetime.
- Controlled host-guard attachment race test and a bounded retry after confirmed
  old guard exit. An alive former core still prevents attachment.

- Explicit journal reconciliation with a confirmed CAS barrier, exact prior-owner
  cleanup, direct host compatibility checks, incarnation adoption, and replacement
  within the complete retained transition reservation.
- Recovery of running intent after request expiry, lost acceptance, lost host
  binding, lost completion, and host-guard restart.
- Increasing activation sequence numbers and atomic closure of unused attempts,
  so delayed old owners cannot start after a replacement has settled.
- Abrupt coordinator loss during a two-worker drain, including an unstarted move.
  Original requests, Refs, committed state, and transition claims survive.
- Recovery on an independent host while another deployment retains uncertain
  claims after owner death or recorded-source unavailability. The source test
  stops a peer without passing a death receipt to recovery; it is not a live
  partition proof. The target stays empty while the independent host is ready.
- Generated 32-event histories with seeds 7, 41, and 83, checked against a model
  of committed count, revision, request bindings, desired state, and claims.
  Repeated restart, reconcile, duplicate requests, and lost write replies preserve
  one Agent and stable receipts. Each history ends with stop and stopped restart.
- Real Bedrock and Mnesia running-state recovery, followed by stop and a further
  restart that preserves stopped intent.

- S4 pure channel and subscription DSL lowering, exact channel scope and core Ref
  resolution, and normal journal definition round trips.
- S4 one-hop envelope checks, unchanged Signal values, validated numerical limits,
  atomic local admission slots, and bounded duplicate-cache retention.
- S4 connected-BEAM sender and local Bus receiver with one outstanding envelope
  per receiver-issued credit. Local and real peer tests cover saturation, lost
  acknowledgements, duplicate/cache handling, and retained credits on disconnect.
- S4 explicit local publication with pre-append admission, bounded export tasks,
  result counters, uncertainty, deterministic fanout, and checked task exit.
  A real three-peer test proves selected-host delivery and no import loops.
- S4 mirror supervision tied to exact activation and core lifetime. Retained
  resource records cover discarded creation replies, close admission before
  cleanup, and prevent settlement after abrupt mirror or export-supervisor loss.
  Local tests and two real peer tests cover ownership, partition, and cleanup.
- S4 local bindings to exact ready Agent incarnations, required/optional readiness,
  partial rollback, and late attachment results. Mirrors now own fixed interested
  host connections and report transport health separately from binding readiness.
  Peer tests cover actual Agent delivery, setup refusal, and sender loss.
- S4 declarative setup under the deployment Owner, configurable limits, pure
  participant checks, required receipts before completion, and publication/status
  facade APIs. Static admission is open; S5 now adds managed movement below.
  Telemetry barriers cover required attachment and concurrent publication limits.
- Three S4 living examples under `examples/07_federation`, with mirrored tests.
  They prove host/deployment/namespace isolation, real bidirectional transport,
  no import loops, duplicate suppression, and controlled publication bounds/loss.
- S4 requirement audit and extra checks at declaration/admission boundaries,
  pending publisher rejection, static drain rejection, and current binding loss
  without historical operation changes. The full and production checks pass.

- S5 mirror resource revisions, exact-owner closure, stale-control rejection, and
  replacement only after confirmed cleanup. New local and two-node tests retain
  the same Agent and logical binding ID across replacement, use new subscription
  IDs, and prove that stale stops cannot terminate the new mirror.
- S5 bridge/task ownership separation. A mirror can confirm export-task cleanup
  after a bridge crash. Abrupt mirror or export-supervisor loss remains uncertain.
  Explicit bridge-only repair and managed movement are now recorded below.
- S5 portable binding intent in the aggregate journal. Initial acceptance records
  planned identity; setup records accepted host incarnations before mirror
  creation and required completion before deployment completion. Stop records
  detach before cleanup. Full activation recovery advances binding revisions.
- S5 lost-write barriers, legacy snapshot migration, and real Bedrock/Mnesia
  binding recovery. Actual Agent and mirror exits precede reconstruction; Agent
  persistence retains prior events. A separate live 64-binding backend fixture
  measures encoded size and confirms all owned component cleanup.

See the slice plan appendices for decisions and evidence. S4 static-host acceptance
is complete. S5 and the static cumulative example are complete for their
stated scope. The [S6 audit](../06_host-providers/plan.md#real-docker-acceptance-and-s6-audit)
now records real Docker and provider cumulative acceptance. S7 remains.
The instance service accepts explicit memory mode or a configured core adapter
and trusted registry. Running or unfinished records start at
`:reconciliation_required`. `Jido.Cluster.reconcile/1` now performs the explicit
recovery pass. Its `:ok` is acceptance, not completion. Observe `recovering` on
`status/1` and deployment readiness on `status/2`.

## Continue in slice order

The S1–S6 contracts, required examples, and both cumulative provider modes have
passing local evidence. Continue with S7.
Static channel admission is open. Publication receipts do not promise Agent
execution. Managed instance drains now use journaled source retirement and target
attachment. Direct legacy planning retains its static channel restriction.
S7 needs measured entity granularity and supported legacy identity migration.
The local Docker Engine now responds and the S6 real-provider tests pass. The
dedicated CI job has no remote run while this worktree remains unpushed.

The four S3 example folders now exist with six mirrored tests. They use real
Bedrock on the control peer for the journal and shared Mnesia for Agent state.
The source-partition case keeps the source alive, blocks replacement through a
service restart, then proves recovery after reconnection. Scheduler cleanup now
retains its Controller while a known source or target host is unreachable.
Recovery tests also interrupt host-adoption and replacement-intent writes. The
real Bedrock service test stops the Repo while the service and Agent remain alive;
mutations stop, claims remain, and recovery succeeds after Repo restart.

Keep the moved-target recovery limit explicit. The journal stores
`initial_selected` separately from the desired/current selection. Core validates
its stored target against that original definition. It can initially restore a
source whose movement has not started, so recovery confirms all retained source
and target reservations before starting Core. It releases retired source claims
only after target readiness and checked host release.

When the original and desired selection differ, recovery currently requires Core
persistence. Without it, `:placement_restore_requires_persistence` retains claims
and starts no replacement. A journal adapter alone does not prove the saved Core
target. Review a public Core mechanism before claiming broader volatile-target
recovery. Cluster does not decode or alter Core target/checkpoint records.

## Recovery contracts to preserve

`Instance.Store` rereads and confirms a new CAS revision before recovery effects.
A reread alone cannot settle a delayed unknown write. Unknown writes block the
store, and public claims include both the prior and possible candidate sets.
Normal task callbacks and recovery callbacks address the original service PID.

`Instance.Recovery` first settles owners and reconciles host claims for each
pending deployment. It then starts candidates whose selected hosts have no
uncertain claims. `RecoveryState` retains historical operation identity and
separate current recovery state. An expired request remains expired. A drain can
only complete after every required deployment has confirmed current recovery.

Activation evidence is kept before the OwnerSupervisor in the application tree.
It survives named service shutdown in one VM. Each attempt has a sequence number.
An unused attempt is closed atomically; a delayed owner cannot claim it afterward.
Only an exact live owner can settle a claimed attempt. Owner death without
confirmation and a changed runtime remain uncertain. There is no disk receipt,
VM-loss proof, lease, or automatic cross-node takeover.

Host guards retain claims in `:persistent_term`, keyed by the core name and PID.
A guard restart closes control until exact reconciliation. Recovery records the
new incarnation before reopening the guard. Direct checks include namespace,
protocol, release, persistence identity, modules, allocation, and retained claims.
The record is VM-local and is not a substitute for the journal. Its update cost
still needs the S7 scale review. Fixed allocation partitions remain unchanged.

## Work boundaries

Cluster is on `v3-spike`. Preserve the original uncommitted design changes,
including the old package-purpose deletions. No commit, push, or CHANGELOG change
was made. No sibling source was changed by this task. Other tasks continue to
change local dependencies. At the latest inspection Core is on
`codex/v3-findings-core` at `f381817e`, with a clean working tree. Other task
changes can cause recompilation;
record test evidence only after a complete isolated run.

Do not use skills or sub-agents. Continue the active seven-slice goal without an
additional approval gate. Do not mark it complete until the required real Bedrock,
Docker, examples, and full verification pass. Design review remains Pending approval.

Run Mix commands serially. Do not mix tests with compilation in the same build
environment. An earlier overlapping run loaded mixed peer code and was discarded.
The full suite passed after the recovery implementation and test-helper
refactoring. The prior complete suite passed 170 tests before this increment.

## Latest verification

`mise exec -- mix quality` passes format, warnings-as-errors compilation, strict
Credo, and Doctor. Doctor reports 128 passing modules and complete documentation
and spec coverage. The isolated `mise exec -- mix test.all` run passes 298 tests
with seed 0 in 105.1 seconds. This final run includes the publication guard during
pending repair. This increment adds three local repair tests and the real
Bedrock bridge restart example. The existing peer deployment test now proves
native connection repair and fresh delivery to the unchanged Agent.
Existing real Bedrock/Mnesia binding recovery, 64-live-binding, movement,
transport, and example tests remain in that run. Expected owner-kill, Bus-loss,
partition, and single-node Bedrock messages appeared.

The preceding generation increment fixed a Bedrock fixture cleanup race. Its
exact placeholder monitor still proves cleanup when the process exits before its
stop call. That regression remains covered by the current backend tests.

`MIX_ENV=prod mise exec -- mix compile --warnings-as-errors` passes with `lib` only.
No additional transport dependency is needed. The cold dependency build reports
existing warnings in `uniq` and `sweet_xml`; Cluster compilation passes. S4's
numbered requirements and living examples now have an explicit evidence map.
S5–S7, cumulative examples, and real Docker proof remain pending.

The backend fixture contains 16 deployments, 32 transition claims, 64 request bindings,
16 pending drain steps, activation sequence numbers, recovery metadata, and
original selections. Its latest full run measured 53110 bytes and 25 Bedrock
CAS writes in 45791 microseconds. This is a fixture measurement, not a throughput
guarantee. Bedrock uses one peer with relaxed filesystem durability; these tests
do not prove machine or replica failure. The separate Agent persistence setting
remains explicit.

The separate federation fixture has one deployment, eight Agents, eight channels,
and 64 live required bindings. Its complete ready journal record measured 29,572
bytes on Bedrock. Every binding was checked through public runtime status before
stop; Agent, mirror, and component cleanup were checked afterward. This fixture
does not prove a scope containing the maximum of every independent count limit.

The example catalog checks pass for 30 source/test folder pairs, tags, source
files, and changed local links. No test uses private process state or a timed absence assertion.
`mise exec -- mix docs`, whitespace checks, and the new catalog link checks pass.

## S4 implementation seams

`Federation.Declarations` stores version-1 metadata under
`jido.cluster.federation`. DSL entities are `federated_channel` in resources and
`federated_subscribe` in connections. They name exact allowed types and root
Agent keys; they do not create core local-Bus connections. `read/1` also validates
direct metadata. `resolve/2` builds `{namespace, topology_id, channel}` identities
and exact core Refs. Planner accepts static channels after pure validation;
managed deployment setup requires binding receipts before completion.

`Limits` defaults to 16 KiB per envelope, 32 slots and 512 KiB per direction,
32 participating hosts, and 1024 duplicate identities for 60 seconds. Limits and
hard configurable ceilings are validated. `Envelope` preserves the Signal term,
uses a distinct export ID, enforces one hop, and rejects runtime data and excess
size. `Dedup` rejects new exports at saturation instead of evicting unexpired IDs.
Only retain its candidate cache after successful local append.

`Gate` uses a fixed ETS slot set and atomic insertion in each caller. It reserves
maximum-envelope bytes per slot. Effective slots are the lesser of count and
byte-budget/maximum-envelope-size. Caller exit or timeout never reclaims a slot;
a queued message might remain. The bridge owner releases exact permits after
completion, or closes the generation. Owner exit removes the table. This is a
local primitive; remote calls cannot access another VM's ETS table.

`Federation.Transport` now defines the internal `transmit/2` callback. The
`Transport.Connected` sender acquires a one-slot local gate before payload mailbox
submission. `Transport.Receiver` grants that process one credit and reserves one
maximum-size inbound slot for its lifetime. Payloads use native `Process.send/3`
with `:nosuspend` and `:noconnect`, without per-message RPC tasks or retries.
Acknowledgement timeout returns uncertainty while the sender slot stays charged.
Late acknowledgement releases it. `:noconnection` retains both sides' uncertainty;
confirmed receiver exit closes the sender, and confirmed sender exit frees its
credit. Reconnection alone does not reclaim a disconnected sender's credit.
Explicit lifecycle reconciliation remains S5 work.

The receiver validates the envelope, checks its bounded duplicate cache, and uses
the real local Signal Bus. It retains a candidate cache update only after append
succeeds. It never exports imports. Config validation checks local Bus PID, host
list, scope, allowed types, and limits. Sender/receiver public status exposes counts
and uncertainty. Crash status removes payloads. Payload budgets exclude fixed
protocol overhead and VM headers; setup/status are control operations. Runtime
publication must reuse established connections instead of creating one per event.

`test/support/federation/bus_store.ex` is a test-only real Memory Store wrapper
with explicit hold/reject controls. Transport tests prove 128 concurrent callers
cannot add a second payload behind a blocked credit. Peer tests use three hosts,
including a spare rejected at capacity, and a separate two-host partition case.
The partition case stops the sender while disconnected, reconnects, and confirms
that its old credit remains uncertain. All fixture resources have checked cleanup.

`Federation.Bridge` now implements explicit local publication around the gate.
It validates the Signal, reserves in the caller before mailbox submission, appends
to the supplied local Bus, and submits one bounded task per publication. A receipt
identifies scope, original Signal ID, fresh export ID, and selected destinations.
It confirms `local: :accepted` and `outbound: :submitted`. An append rejection frees
the slot and sends nothing. A timeout reports uncertainty without cancelling work
or freeing its slot. Retrying creates a new export; it is not business replay.

Targets are unique remote hosts, bounded to `max_hosts - 1`, and visited in sorted
order. One failure does not prevent later submissions. A standalone bridge owns
its task supervisor; a mirror supplies a separate dedicated supervisor under its
own local tree. The bridge holds each permit until the task's `DOWN` confirms exit, even after
a result message arrives. Unknown task-start outcomes retain their slots until
closure and expose `submission_uncertain`. A target update requires zero charged
slots, including admitted or unresolved callers. Shutdown closes the gate and
confirms owned task shutdown; supplied Bus and transport connections remain with
their separate owners. `Channel.validate/3` shares static validation with Receiver.

Status has bounded per-host failures and counters, not stored payload history.
Bridge `health` is last observed submission health. It does not observe idle
connections or required Agent bindings. Correlated export telemetry omits Signal
payloads and does not write the deployment journal. The bridge does not subscribe
to the Bus: imports and ordinary Bus publications cannot create exports.

`test/support/federation/recording_transport.ex` is a bounded test transport with
hold/failure controls. The bridge suite covers 128 concurrent capacity rejections,
append failure, caller timeout, post-acceptance failure, fanout, target updates,
and checked task exit. The three-peer publication test connects real transport
in both directions, then proves no loop, no delivery to the uninterested host or
second deployment, and unchanged Signal data. It manually owns its components;
that fixture does not prove required binding readiness.

`Federation.Mirror` now owns a Bus, Receiver, Bridge, and export task supervisor
under application supervision. It registers a stable local key, then claims a
host/channel resource record with Activation before it starts children. The
record stores the exact mirror PID. Up to 256 records fit one activation. Repeated
deployment claims preserve these records. They stay in VM memory, outside the
journal. Mirror configuration is immutable within a generation and tied to the
exact core PID. The local Bus log is bounded to 1024 records.

`Activation.close/2` closes new resource admission before cleanup. The owner then
calls `Mirror.cleanup/3` for every recorded host/channel before stopping core.
An unclaimed channel is safely absent only after admission closes. A claimed
resource needs a receipt from its exact process. `Activation.settle/2` rejects
while any resource remains unsettled. Dead mirror PIDs and missing Registry
entries retain uncertainty. S5 now permits the deployment owner to close one
resource revision and prepare its immediate successor after exact cleanup. This
replaces the record in place. It does not infer cleanup from missing processes.

Mirror shutdown waits for owned component exits and orderly export-supervisor
exit. The mirror owns the dedicated task supervisor independently of the bridge;
`Bridge.work_owner/1` also exposes that public supervision handle.
Abrupt mirror or export-supervisor loss cannot produce a receipt. Core and
confirmed owner exit close local resources; owner disconnect reports uncertain
control and retains them. Remote cleanup has a five-second request deadline.
The Scheduler now handles a closed owner's work refusal as an uncertain result,
rather than storing that error as a task reference.

Local mirror tests cover concurrent starts, discarded replies, closure races,
configuration checks, component/core/owner exit, and retained cleanup uncertainty.
Two ownership peer tests attach mirrors to actual deployment owners and verify normal stop
and live-partition recovery. They use the real Mnesia journal.

`Federation.Binding` now validates an exact local Ref, accepted PID, core lifetime,
and Agent readiness before attachment. It creates one ephemeral Bus subscription
per exact allowed type and reuses those IDs on repeat attachment. The Bus sends
directly to the Agent's normal handler. Binding does not receive event payloads.
Partial failure removes only IDs created by that attempt. A conflicting foreign
ID remains. An attachment timeout leaves work running; a late result can complete
the same attempt. Detach removes owned routes and closes the binding. Confirmed
Bus death proves its routes are gone. Agent or core death reports a lost binding.
The process does not find and attach a replacement Agent automatically.

`Mirror.ensure/1` accepts up to 64 distinct declarations in `bindings`, each with
`ref` and `required`. `Mirror.attach/3` starts a supervised binding for that exact
target. A different target is rejected in this generation. Required missing
bindings produce pending/degraded readiness; optional missing bindings remain
visible without blocking required readiness. The instance facade now reports
these current observations. Binding process loss closes the mirror generation;
Agent loss leaves the mirror alive and changes its binding observation.

`Mirror.connect/2` accepts a fixed set of unique, known remote receiver descriptors
for the exact channel. `Federation.Connections` creates one owned sender attempt
per host. Repeated setup reuses the result, including failed attempts. Failure
retains a closed target, so publication still names the interested host and counts
a known pre-send rejection after local acceptance. Sender exit degrades transport
health without removing local bindings. Connection handles use the existing gates;
there is no new payload mailbox. Before configuration, health is pending; a
configured empty destination set is healthy. This static generation rejects an
interest change. S5 still owns replacement, movement, and reconnection policy.

Eight binding tests use real AgentServers, including partial rollback while the
Agent remains alive and a telemetry barrier for a lost attachment reply. A mirror
test checks required/optional readiness. Two peer binding tests use actual
deployment owners and owned native connections. They prove remote import through
the Agent handler, remote-PID rejection for a local Bus, sender reuse, isolated
transport loss, receiver-capacity refusal, and checked cleanup. The channel setup
is explicit in these tests; it is not yet driven by topology declarations.

Declarative deployment is now integrated through `Federation.Runtime`. Its pure
plan resolves accepted Ref locations and counts the control publisher plus
subscribing hosts. The deployment Owner runs setup after Core readiness, and
required attachment receipts precede initial completion. Mirrors own the fixed
connections and cache their publisher handles. Unconfigured mirrors cannot publish.
Instance config validates `federation` limit overrides. Direct legacy Scheduler
startup rejects channel declarations without managed deployment ownership.

`Cluster.publish/5` obtains context with IDs only, then reserves the caller-local
Bridge gate before sending the Signal. Publication currently runs on the control
node. `federation_status/2` and `status/2` read current observations outside the
journal mutation path. Current health does not change historical operation
completion. Managed channel moves now use the S5 transition protocol below.
Direct legacy planning keeps its static restriction. No sibling source change has been needed.

Six local deployment tests prove the full declaration path, required attachment
barriers/failure, original Signals, stop cleanup, limit validation, and sixteen
concurrent capacity rejections while one local append is held. One three-peer test
proves interested-host-only delivery, no import loop, separate health after sender
loss, unchanged completed history, and exact resource cleanup.

All three `07_federation` examples now exist with source, README, and mirrored
`:example` tests. Their section fixture starts fixed hosts and checks deployment,
Agent, mirror, guard, Core, and peer cleanup. The first two examples use native
connected transport. The bounded-publication example uses the existing recording
transport to control submission; simulated acknowledgements do not claim delivery.

## S5 movement checkpoint and next work

Managed instance drain now records desired binding revision and a portable
`federation_transition` before source cleanup. The exact Owner task retires all
channel mirrors for that deployment, records retirement, prepares successor
resource revisions, moves Core, and attaches the target after readiness.
Status exposes the pending transition; required completion clears it. Previous
resource history prevents revision reuse when returning to an earlier host.

New evidence includes two pure transition tests and four three-node movement
tests. They cover normal movement and return, stale stop and target rejection,
foreign resource-control rejection, and lost journal replies at retiring,
retired, and attaching phases. Explicit recovery retains Ref identity, original
request identity, committed state, and conservative source/target claims.
The old S4 static drain rejection test now proves managed movement in memory mode.

The first S5 living example, `08_01_subscription_move`, uses a real Bedrock
journal and shared Mnesia Agent persistence. It checks both old mirrors, the
source Agent, delayed source creation rejection, target delivery, and final
resource cleanup. Its focused test passes with seed 0. Six focused transition
and movement tests also pass. See the [S5 requirement map](../05_federation-lifecycle/plan.md#journaled-subscriber-movement).

Explicit bridge and connection repair is now integrated. When placement and
journal state are ready, `reconcile/1` starts one bounded federation pass. It
observes current health outside the service, then journals same-placement
retirement intent through the exact pass task. The Scheduler Owner runs a
separate binding operation that checks the existing Controller, accepted
placements, and Agent PIDs. It makes no Agent start, stop, movement, or Core
reconcile call. Source mirror settlement and the retired journal write still
precede successor preparation and target attachment.

Repair retains activation, Ref, logical binding ID, host incarnation, complete
capacity claims, and historical operation records. `binding_repair: :running`
reports the active service attempt. The transition records portable pending
steps; structured reasons retain failure evidence. The service blocks stop and
drain of the active deployment with busy errors while independent requests can
proceed. Healthy reconciliation retains mirrors and exact journal bytes.
Publication is rejected while repair or its transition is pending, including the
interval before the required completion journal receipt.

Three local repair tests cover retained Agent/claims/history, a held retirement
write before mirror creation, healthy no-op reconciliation, and independent
start/publish/stop while a public retirement telemetry barrier holds cleanup.
The existing three-peer deployment test now repairs a lost sender and checks
fresh native delivery to the unchanged Agent. A new retirement telemetry span
reports namespace, topology, activation, binding revision, phase, and result
reason without Signal payloads.

The second living example, `08_02_bridge_restart`, uses real Bedrock. Its
controlled transport fixture holds one export before remote submission; this
proves interruption and exact task cleanup, not real remote acceptance. Repair
rebuilds native connections and delivers a fresh event to the unchanged Agent.
The interrupted event is not replayed. Both S5 examples pass their focused run.

The final S5 increment adds `08_03_shared_cleanup`, `08_04_uncertain_attachment`,
and `11_01_deployment_lifecycle`, all with real Bedrock journals and checked cleanup.
The cumulative example covers managed and attached Core, delayed target visibility,
actual worker cleanup and reactivation, partial drain restart, retained stopped
intent, independent work during source uncertainty, and final resource cleanup.
Native BEAM connections are VM-owned. Each deployment owns its own senders and
mirrors, so no shared application sender needs a reference count. The shared
cleanup example retains the other deployment's exact PIDs and native delivery.

An empty host guard can now reconcile an old owner during confirmation only if
direct host evidence and the ledger exclude all prior claims. It checks exact
incarnation, compatible scope/capacity, empty actual claims, and only new reserved
claims with no host incarnation. The existing HostRuntime reconciliation call
checks the empty set again atomically. Bound and uncertain claims still require
full recovery. A focused attached-Core regression covers this cumulative-test gap.

Managed repair now has an abrupt-mirror-loss regression. Two repair attempts keep
the same Agent, claims, completed request, and structured uncertainty; no mirror
replacement appears. Stop retains uncertainty. Four added movement cases hold
retiring, retired, attaching, and ready journal replies. They kill the source or
target bridge where one exists and verify bridge absence between retirement and
setup. Target loss before the ready reply changes live readiness; explicit repair
retains the Agent and historical drain completion.

Unknown journal writes still use full activation recovery. Bridge repair cannot
bypass the journal reload or exact cleanup requirements. Recovery after movement
still needs separate Core persistence when initial and desired placement differ.
Keep the full S1–S7 objective, real Bedrock/Docker requirements, and both cumulative
examples intact. No commits or sibling source edits were made.


## S5 final checkpoint and S6 next work

`mise exec -- mix quality` passes with 141 modules and complete documentation and
specification coverage. `mise exec -- mix test.all` passes 308 tests with seed 0
in 127.5 seconds. Production compilation with warnings-as-errors and `mix docs`
pass. All 33 stable example folders have README/source/test pairs and valid local
links; inherited/direct example tags are checked. `git diff --check` passes.
The real Bedrock 64-binding fixture measures 29,474 bytes. The S3 aggregate
measures 53,110 bytes and 25 CAS writes in 48,508 microseconds. Full logs are in
`/tmp/jido-cluster-s5-system-{quality,all,prod,docs}.log`.

S5 is complete for its stated best-effort scope. Review rows remain Pending
approval. The seven-slice goal remains active. S6 has the initial contract increment
below; its service integration and Docker proof remain. S7 is not implemented.

Initial S6 read-only preparation found a local LitterBox checkout at
`/Users/mhostetler/Source/Jido/proj_jido_workspace/litter_box`, clean on `main`,
revision `2b9ac96da48e0c2eb46c7558a04d025abc09c4e8`. Its Docker session path uses
an ephemeral unique container name and masks cleanup errors. Review the acquire,
inspect, and release contracts before choosing reuse; do not add the full sandbox
API as a dependency. The provider needs persisted step identity, exact resource
incarnation, bounded inspection, and confirmed deletion.

Docker context `orbstack` points to
`unix:///Users/mhostetler/.orbstack/run/docker.sock`. `orbctl status` reports
Running, but Docker info and a direct socket `_ping` timed out. The default
context has no `/var/run/docker.sock`. These read-only probes created no resource.
Do not restart shared infrastructure without first checking its effect on other
work. Provider design and controlled contract tests can proceed while this is
resolved; real Docker acceptance remains required.


## S6 initial contract increment

The optional `Jido.Cluster.HostProvider` behaviour now defines bounded acquire,
inspect, release, and optional discovery contracts. `HostProvider.Step` and
`Resource` encode exact portable identity without runtime options. The pure
`HostProvider.Release` decision retains borrowed resources, running intent,
incomplete cleanup, changed identity, and never-observed unknown acquisition.
Discovery first requires recorded adoption. Release acceptance requires a later
inspection before deletion is reported.

Seven controlled tests pass with seed 0. The release model checks 96 combinations
of ownership, intent, claims, Agent cleanup, binding cleanup, and admission state.
The fixture tests lost replies, duplicate acquisition, bounded discovery, unavailable
inspection, stale release, and closed-step rejection. `mix quality` passes with
145 modules and complete doc/spec coverage. These tests do not integrate the
provider into the deployment service or establish real Docker behavior.

Next: add durable host sessions and facade acquire/release requests to the existing
scope authority. Integrate them with the existing journal, retention, actual-task
callback checks, recovery, and admission exclusion. Keep configured node atoms
and provider options outside records. Recheck exact provider authority as well as
resource ID and incarnation: changing a runtime endpoint must not let absence in
another provider settle an old resource. Add the controlled service tests before
Docker. No live provider resource has been created by this increment.

Important unresolved external-effect case: after unknown acquire, an absent read
cannot exclude a late creation. The pure decision retains uncertainty. The fake
uses a closed-step set, but Docker still needs a tested strategy for delayed
calls and release. Never infer that fixture behavior proves a provider guarantee.


Latest complete suite after the S6 contract types: 315 tests, zero failures,
seed 0, 122.4 seconds (`/tmp/jido-cluster-s6-contract-all.log`). Quality passes
(`/tmp/jido-cluster-s6-provider-quality.log`). No code task, provider call, or
external resource remains active from these tests. OrbStack doctor also passes;
its Docker API remains unresponsive. No infrastructure restart was attempted.

Production compilation with warnings-as-errors and `mix docs` pass after the S6
contract increment. Local documentation links and `git diff --check` pass.
No commit, infrastructure restart, or sibling source change was made.

## S6 durable sessions and controlled service integration

The service now records provider inventory and HostSession intent in its existing
scope journal. Public acquire/release requests use retained request tokens and
actual-task progress checks. The journal records the attempted step before an
acquire call, exact resource identity before runtime checks, and a cleanup receipt
before deletion. Provider hosts remain closed until direct checks pass. Owned
runtimes require the exact boot step and a dedicated Core allocation. Guard
restart cannot change that step for the same Core PID. Borrowed release retains
infrastructure. Runtime provider options remain outside the journal.

Release retains hosts with claims and checks Core Agents, federation mirrors,
and host claims before recording deletion intent. A retained retirement step
prevents new registration during deletion. Unknown journal outcomes prevent
dependent effects. Host status exposes possibly committed intent and closed
admission. An unresolved release cannot be replaced by another request identity.
After a saved cleanup receipt, an absent provider observation can finish release
without contacting the deleted runtime.

The controlled suite checks lost replies, wrong namespace and boot identity,
borrowed retention, shared claims, held and lost deletion receipts, abrupt owner
loss, expired operation history, unrelated progress callers, and provider checks
before replacement activation. Failed task completion also removes its runtime
busy marker when a journal write is unavailable. Snapshot validation checks host
operation references while allowing completed history to expire.

The full suite before the added Bedrock case passed 335 tests with seed 0 in
134.1 seconds. The focused provider/guard/session suite passed 29 tests with seed
0 in 11.2 seconds. Quality passed for 150 modules with complete doc/spec coverage.

The added real Bedrock service case passes. It preserves the original resource
through a lost acquire reply, abrupt owner loss, and repository restart. A second
owner/repository restart restores committed subscriber state at the same Ref with
a new Agent PID. Fresh federation delivery succeeds. Final release records the
same provider resource in Bedrock. Agent checkpoints use shared Mnesia; provider
effects remain controlled. The complete service test file passes 13 tests in
15.5 seconds (`/tmp/jido-cluster-s6-service-bedrock.log`).

S6 is still incomplete. Next work is the real Docker adapter and prepared release,
the five provider living examples, the provider cumulative variant, and the final
requirement audit. S7 has not started. The Docker API socket still times out.
An explicit request to restart OrbStack is pending because the unavailable API
prevents inspection of other active containers. Do not restart it without the
user's answer. No restart or real Docker resource creation has occurred.

Read the [S6 service evidence](../06_host-providers/plan.md#controlled-service-integration)
for the contract and requirement map. Review rows remain Pending approval.

Latest complete suite: 336 tests, zero failures, seed 0, 139.2 seconds, including
the new Bedrock provider case (`/tmp/jido-cluster-s6-service-all.log`). Quality
passes for 150 modules with complete documentation/specification coverage
(`/tmp/jido-cluster-s6-service-quality.log`). Production compilation with
warnings-as-errors passes (`/tmp/jido-cluster-s6-service-prod.log`). All 33 existing
example source/README/test pairs and their direct or inherited tags pass the
catalog check. Local documentation links and `git diff --check` pass.

The unchanged Bedrock bound fixtures report 29,513 bytes for 64 live bindings
and 53,149 bytes for the aggregate. The aggregate writes 25 CAS records in 47,602
microseconds. These are fixture observations, not performance guarantees.
Core remains clean on `codex/v3-findings-core` at `f381817e`. No commit, sibling
source change, or infrastructure restart was made.

The documentation build also passes without warnings
(`/tmp/jido-cluster-s6-service-docs.log`). No Mix command remains active.

## S6 Docker API increment

`HostProvider.Docker` now implements local Engine acquire, inspect, release, and
bounded discovery. It uses optional Req with no retries or redirects, finite
HTTP limits, and a 256 KiB response body limit. Explicit configuration supplies
the socket or loopback endpoint, Engine ID, and prepared container configuration
or full borrowed container ID. A changed Engine is refused before inspection.
Create names and boot environment retain the recorded step. Delete addresses
only a verified immutable container ID and does not remove volumes. Partial boot
and lost replies retain uncertainty. Borrowed mode rejects effects directly.

Twelve protocol tests pass over a real local HTTP server, including a Unix socket.
They cover closed replies, exact paths and identity, partial boot, duplicate and
conflicting creation, borrowed mode, stale or malformed observations, finite
response waits, body limits, and bounded discovery. The fixture checks server and
socket cleanup. These tests do not prove real Docker behavior. The adapter has
no tombstone store; the existing scope journal prevents acquisition from being
reissued after a recorded attempt. Runtime options remain outside resource records.

After the optional dependency change, `mix deps.get` succeeds. The full suite
passes 348 tests, seed 0, in 143.8 seconds (`/tmp/jido-cluster-s6-docker-all.log`).
Quality passes for 153 modules with complete doc/spec coverage
(`/tmp/jido-cluster-s6-docker-quality.log`). Production compilation with
warnings-as-errors passes (`/tmp/jido-cluster-s6-docker-prod.log`). The focused
protocol log is `/tmp/jido-cluster-s6-docker-contract.log`.

The next required work is the prepared worker release, a verified Docker network,
real backend contract tests, all five provider living examples, and the provider
cumulative variant. The initial network candidate is host networking with the
existing EPMD and unique loopback BEAM names. This is still a proposal. Read
the [adapter contract and evidence](../06_host-providers/plan.md#local-docker-engine-adapter).
OrbStack restart approval remains pending. No daemon restart or real container
creation has occurred. S6 remains incomplete; S7 has not started. Review rows
remain Pending approval. No commit or sibling source change was made.

The documentation build passes without warnings
(`/tmp/jido-cluster-s6-docker-docs.log`). Local links, all 33 existing example
pairs, and `git diff --check` pass. The real Docker socket still does not answer
the five-second probe. No Mix command remains active.


## S6 prepared worker and controlled examples

The prepared Docker fixture now has a separate application, staged V3 source
build, pinned Dockerfile, and release configuration. Native peer tests verify
step registration, shared Agent state restore, borrowed startup, invalid setup
rejection, and checked process cleanup. Both tests pass with seed 0 in 1.3 seconds.
The earlier full suite passes 350 tests in 139.2 seconds. Quality passes for 153
modules. A separate production consumer builds a native release without Req or
Bedrock; release evaluation confirms both optional modules are absent.

The first three provider living examples now have source, README, catalog links,
and four passing tests with real Bedrock journals and controlled provider effects.
They cover acquisition before admission, release after subscriber cleanup, original
step adoption after owner/repository restart, borrowed resource retention, and
wrong-namespace rejection. The default examples do not claim real Docker proof.
A further service test covers delayed creation after absent inspection and owner
restart; recovery must retain uncertainty until it can adopt and clean the effect.

Read [the S6 increment](../06_host-providers/plan.md#prepared-worker-and-first-living-examples)
for evidence, source links, and remaining acceptance work. `09_04`, `09_05`, real
Docker tests, the provider cumulative variant, and the final requirement audit
remain required. S6 is incomplete and S7 has not started. OrbStack restart approval
remains pending. No daemon restart, container creation, commit, or sibling source
change was made. Review rows remain Pending approval.


Verification after this increment: `mise exec -- mix test.all` passes 355 tests
with seed 0 in 153.1 seconds. `mix quality` passes for 165 modules with complete
documentation/specification coverage. Production compilation with warnings-as-errors
passes. The focused provider contract/service run passes 21 tests in 16.9 seconds,
including delayed creation and the real Bedrock restart case. Its log is
`/tmp/jido-cluster-s6-late-creation.log`. The full, quality, and production logs use
`/tmp/jido-cluster-s6-provider-examples-{all,quality,prod}.log`. All 36 stable example
source/README/test pairs have matching folder IDs and direct or inherited example
tags. Local documentation links and `git diff --check` pass. Core is still clean
on `codex/v3-findings-core`.

The documentation build passes without warnings
(`/tmp/jido-cluster-s6-provider-examples-docs.log`). It includes the 355-test
checkpoint. No Mix command remains active.


## S6 cleanup examples and explicit Docker runner

All five provider examples now have controlled implementations. The two release-guard
cases retain a live remote mirror and provider resource through a partition, then
settle cleanup after reconnect. A changed resource ID/incarnation at the same step
is retained by both direct stale release and scope reconciliation. The abrupt-death
case uses four workers with real Bedrock: a lost deletion-receipt reply prevents
the provider effect, then owner death and repository restart resume only the saved
target cleanup. Independent live, borrowed, and replacement resources remain.
The independent Agent restores committed state at the same Ref and receives a new
event; stopped target intent remains stopped. Final cleanup is checked.

The controlled inventory is not Docker infrastructure. Replacing an observation
does not replace a native VM. Read the
[S6 evidence](../06_host-providers/plan.md#cleanup-examples-and-explicit-docker-runner)
and each example's limits.

The explicit `mix test.docker` command selects two prepared backend cases. It uses
only the peer tag, an explicit local socket, and a prepared image pinned by local
image ID. Its fixture registers scoped cleanup before acquisition and checks exact
identity before deletion. The file is outside the default test pattern, with a
narrow documented filename-lint exception so Elixir 1.18 also keeps it explicit.
No stable example is skipped by this choice.

Both missing configuration and the unavailable Engine invalidate these Docker
cases and return exit 2. Logs are `/tmp/jido-cluster-s6-docker-prerequisite.log`
and `/tmp/jido-cluster-s6-docker-unavailable.log`. The latter ran with the explicit
OrbStack socket and planned image tag; Engine inspection timed out before any
resource creation. These are prerequisite-failure results, not passing Docker tests.
The direct five-second ping also timed out. Restart approval remains pending.

Remaining S6 work includes the Linux image build, verified network, real backend
fault cases, real versions of the five living examples, the provider cumulative
variant, and the final requirement audit. S7 remains unstarted. No commit, sibling
source change, container creation, or daemon restart occurred. Review rows remain
Pending approval.


Verification after this increment: the complete default suite passes 358 tests,
zero failures, seed 0, in 159.9 seconds. This includes all seven controlled tests
across the five provider examples. The explicit Docker cases are not part of that
pass count; both are invalid because Engine preflight failed. Quality passes for
173 modules with complete doc/spec coverage. Production compilation with
warnings-as-errors passes. Logs use
`/tmp/jido-cluster-s6-cleanup-examples-{all,quality,prod}.log`. All 38 stable example
pairs and their tags, local links, and `git diff --check` pass. Core remains clean
on `codex/v3-findings-core`. No Mix command remains active at this checkpoint.

The documentation build also passes without warnings
(`/tmp/jido-cluster-s6-cleanup-examples-docs.log`). No Mix process remains active.


## S6 controlled cumulative preparation

The new `11_02_provider_lifecycle` uses the same shared scenario as the static
`11_01` example. Four focused cases pass in 16.4 seconds: static and controlled
provider backends, each in managed and attached Core modes. The shared scenario
retains pending visibility, partial-drain restart, actual Agent exits, committed
state restore, uncertain source claims, independent progress, restored federation,
and checked cleanup. Provider checkpoints keep exact resource identities through
recovery. Final scope release deletes only two owned resources and retains the
independent borrowed resource and guard. Bedrock retains those final host phases.

The explicit Docker backend file now prepares four cases, including failed
bootstrap and owner/Bedrock restart after a withheld successful acquisition.
Its fixture records original steps before effects for exact failure cleanup and
keeps credentials out of its server state. The worker application includes the
small federation topology used by that backend case. The staged production
consumer compiles with warnings-as-errors. The four explicit cases compile but
are invalid with exit 2 when prerequisites are absent; none is passing Docker
evidence. The real Docker example and cumulative runners are still missing.

Read [the current S6 increment](../06_host-providers/plan.md#provider-cumulative-preparation-and-expanded-docker-cases)
for source links, proof limits, and logs. S6 remains incomplete and S7 unstarted.
No commit, sibling source change, daemon restart, or container creation occurred.
The pending OrbStack restart request has no answer. Review rows remain Pending
approval.


The full default suite now passes 360 tests, zero failures, seed 0, in 167.7
seconds (`/tmp/jido-cluster-s6-provider-system-all.log`). All 39 stable example
source/README/test pairs and their tags have matching folder IDs. Local links
and `git diff --check` pass. The expanded staged worker also assembles a native
release; it constructs its federation topology while Req and Bedrock are absent
and Node distribution is not started. Build logs are
`/tmp/jido-cluster-s6-docker-expanded-{compile,release}.log`.

The direct Unix-socket HTTP ping also times out. Docker contexts list only the
unavailable OrbStack socket and the absent default socket. OrbStack's activity
monitor supplies no usable running-resource inventory; its empty display is not
evidence that a restart cannot affect other work. The monitor was closed without
any stop or kill action. Restart approval remains pending.


Final checks for this increment: quality passes for 178 modules with complete
coverage, and production compilation with warnings-as-errors passes. The configured
Docker command selects all four prepared backend cases and returns exit 2 after
Engine preflight times out (`/tmp/jido-cluster-s6-docker-expanded-unavailable.log`).
All four cases are invalid, with no container effect. The production log is
`/tmp/jido-cluster-s6-provider-system-prod.log`. Core remains clean on
`codex/v3-findings-core`. No Mix process remains active at this checkpoint.

The documentation build passes without warnings
(`/tmp/jido-cluster-s6-provider-system-docs.log`). No Mix process remains active.

Next Docker-runner preparation needs an independent control path for each worker
during BEAM partitions. The generated prepared-release script invokes `rpc` with
`--hidden`; Engine exec plus that release command is a candidate that can call
public APIs without a custom domain hook. This has not been tested in a container.
The image also needs the example modules and explicit Core/allocation bootstrap
configuration before it can run the living and cumulative examples. Preserve
independent worker inspection and all existing scenario assertions in that work.


## Worker preparation and independent control

The prepared worker now accepts a Core name from a fixed list of the fixture
Core and seven example Core names. It can also accept one explicit allocation
with a UTF-8 name of 1–128 bytes and a canonical capacity from 1 to 256. These
are test-fixture limits. Missing allocation settings retain the implicit default.
Invalid names or incomplete settings fail before Core starts. The worker
supervisor retains eight bootstrap fields and excludes the distribution cookie.
Three native peer tests pass, including selected Core/allocation observation and
checked process cleanup (`/tmp/jido-cluster-s6-worker-config-test.log`).

The staging script copies the exact five provider example sources, both
cumulative example sources, and the worker-side visibility barrier into the
fixture application. It does not compile ExUnit runners or the full support
tree. A staged production consumer compiles with warnings-as-errors and builds
a native release (`/tmp/jido-cluster-s6-worker-stage-{compile,release}.log`).
The eight staged sources match their originals byte for byte.

The test-only Docker exec transport checks the Engine, exact resource identity,
and running state before it starts a bounded release RPC command. It parses
non-TTY output frames, discards stderr, matches a request ID, and verifies the
exec process ID, container ID, stopped state, and zero exit status. The trusted
ETF transport bounds request/result sizes, refuses compression and trailing
bytes, and kills a timed-out task before it returns. Its values are not journal
records or provider observations. It adds no SDK domain hook or endpoint.
The 20 focused RPC, exec-protocol, and existing Docker-adapter tests pass
(`/tmp/jido-cluster-s6-worker-transport-test.log`).

A separate native release check starts a worker with the provider-cumulative
Core and allocation. All seven example definitions and the barrier load. The
Req and Bedrock dependencies are absent; Jido's optional Bedrock adapter module
is still present as expected. After closing the visible control connection,
the generated release's hidden RPC command can probe the worker while both
visible node lists remain empty. Reconnection and process/EPMD cleanup pass
(`/tmp/jido-cluster-s6-worker-native-control.log`). This is native release proof,
not Docker Engine proof.

The explicit Docker runner now contains five cases, including independent
worker inspection during a BEAM partition. They still require real execution.
The OrbStack socket ping times out after five seconds. Restart permission is
still unanswered; no Engine restart or real container effect occurred here.
The real living-example and cumulative runners remain to be connected to this
transport. S6 is incomplete, and S7 has not started.


Validation for this increment: all 369 default tests pass with seed 0 in 170.6
seconds (`/tmp/jido-cluster-s6-worker-transport-all.log`). Quality passes for 178
modules with full documentation/specification coverage
(`/tmp/jido-cluster-s6-worker-transport-quality.log`). Production compilation
with warnings-as-errors passes (`/tmp/jido-cluster-s6-worker-transport-prod.log`).
The explicit configured Docker run selects five cases and exits 2 after the
Engine prerequisite fails: five invalid cases, no passes and no container effect
(`/tmp/jido-cluster-s6-worker-docker-unavailable.log`).

The documentation build also passes without warnings
(`/tmp/jido-cluster-s6-worker-transport-docs.log`). Changed local documentation
links, all 39 stable source/README/test pairs, and `git diff --check` pass. Core
remains clean on `codex/v3-findings-core`. No Mix or native-check process remains
active at this checkpoint. No commits or sibling source edits were made.


## Shared provider scenarios and initial Docker example runners

All seven provider scenario bodies now live in one test-support module. The
native runners still select the same five example definitions and retain their
assertions. The acquired-topology and lost-acquire-reply examples also have
explicit Docker runners. They call the same scenario functions, use only the
`:example` tag, and are excluded from default selection by exact paths. The
new `mix test.examples.docker` alias selects these two runners. It does not
claim that the other three examples or the cumulative Docker runner are ready.

The Docker example fixture starts one native control node, real Bedrock, and
control-side Mnesia storage. The SDK acquires the worker container. A recorded
step resolves independent worker calls through Engine exec and hidden release
RPC. The call route does not depend on the visible control-worker BEAM link.
After bootstrap, explicit public reconciliation can settle the original acquire
operation. The fixture never issues a second create request to settle it.

Actual resource inventory comes from Docker discovery. The test adapter records
steps before effects and can withhold one real acquire result or fail one
inspection. It retains only steps, action coordinates, and fault mode in its
server state. It does not retain Docker configuration or cookies there. Cleanup
is registered before acquisition; it requires known exact steps, checked Docker
absence, empty discovery, disconnection, and control/journal process exit.

The seven native provider scenarios pass after extraction
(`/tmp/jido-cluster-s6-docker-example-shared-test.log`). The adapter wrapper test
passes with actual local HTTP requests to a controlled Engine protocol fixture:
reply loss and one failed inspection lead to the same resource without a second
create (`/tmp/jido-cluster-s6-docker-example-wrapper-test.log`). This protocol test
is not actual container evidence. Quality passes for 178 modules with full
documentation/specification coverage
(`/tmp/jido-cluster-s6-docker-example-quality.log`).

The real borrowed/incompatible, release-guard, abrupt-cleanup, and cumulative
runners still need integration. In particular, container absence must replace
an unavailable post-deletion worker RPC with direct provider evidence; it must
not be converted into a fabricated `Process.alive?/1` result. Replacement must
use actual resource IDs and incarnations. Preserve the existing multi-host
preservation and partition assertions. S6 remains incomplete; S7 has not started.


The full default suite passes 370 tests, zero failures, seed 0, in 168.5 seconds
(`/tmp/jido-cluster-s6-docker-example-all.log`). The explicit Docker example
command selects both prepared cases, then returns exit 2 because Engine preflight
fails. Both cases are invalid, not passed; no container effect occurred
(`/tmp/jido-cluster-s6-docker-examples-unavailable.log`). Changed local links,
all 39 source/README/test pairs, direct and inherited example tags, and
`git diff --check` pass. Core remains clean on `codex/v3-findings-core`.
OrbStack restart permission remains unanswered, and no restart was attempted.

Production compilation with warnings-as-errors and documentation generation pass
(`/tmp/jido-cluster-s6-docker-example-{prod,docs}.log`). The final fixture
adjustment allows 30 seconds for Docker reconciliation while retaining the native
2-second bound. All seven native provider cases pass again after that adjustment
(`/tmp/jido-cluster-s6-docker-example-shared-test.log`). The full default result
above precedes only this fixture timeout adjustment. No commits, sibling source
edits, Engine restarts, or actual container effects were made in this increment.


## All provider Docker example runners prepared

The explicit Docker example selection now covers all five numbered provider
examples and their seven shared scenarios. Borrowed/incompatible, release-guard,
and abrupt-cleanup runners use only `:example` and remain excluded from default
selection. The fixture supports up to four workers with separate transport
entries, owned or borrowed configuration, and an optional real-Bedrock reply
barrier. The worker namespace override applies only to the selected primary host.

Borrowed resources are created before the scope starts under external fixture
steps. Scope options contain an immutable borrowed ID and no create options.
The shared scenario requires the original container, Core, and guard to remain
alive after scope release and confirms no scope acquire/release effects. The
fixture removes the exact resource only after these retention assertions.

Replacement removes an exact old container, confirms its ID absent, and creates
a new resource outside the scope request path. Docker accepts idempotent release
of the already-absent old ID; that result is checked by ID, and the shared
scenario still requires the replacement to remain running. The default provider
continues to reject its stale handle. The scope must preserve its original
recorded identity and refuse the new incarnation. Existing Docker adapter tests
also cover rejection of an incorrect incarnation for a still-present ID.

Partition cleanup uses independent Engine exec calls while a worker is present.
After confirmed container deletion, cleanup checks that all recorded PIDs belong
to that worker and that the worker has disconnected. It does not invent a remote
`Process.alive?/1` result. Failed or unknown inspection fails cleanup. Connection
cleanup can use the captured exact resource after the fixture ledger has stopped;
it does not try to reconnect an authoritatively absent worker.

The abrupt-owner-death runner prepares four actual container roles: target,
live owned worker, borrowed worker, and an externally replaced owned worker. It
reuses the existing deletion-receipt barrier, real Bedrock restart, selective
cleanup, preserved resource identities, and live-work state/Ref assertions.
Fixture inventory covers both default and external scopes. Cleanup validates
known steps and host names before deleting exact IDs, then checks empty discovery.

All seven native provider scenarios pass after these changes
(`/tmp/jido-cluster-s6-docker-all-provider-native.log`). A focused native-peer
and local-HTTP test passes for confirmed absence, rejection of unrelated PIDs,
unknown-presence failure, and post-ledger connection cleanup
(`/tmp/jido-cluster-s6-docker-provider-cleanup-test.log`). That test does not
establish actual container deletion. Quality passes for 178 modules with complete
documentation/specification coverage
(`/tmp/jido-cluster-s6-docker-all-provider-quality.log`).

All real provider runs still need execution. Cumulative Docker runner integration
remains required. S6 is incomplete, and S7 has not started. The existing OrbStack
restart request has not been answered; no restart is authorized by this update.


Validation for this increment: the full default suite passes 371 tests with zero
failures, seed 0, in 169.6 seconds
(`/tmp/jido-cluster-s6-docker-all-provider-all.log`). The explicit Docker example
command compiles and selects all seven cases, then exits 2 after Engine preflight
fails in each module: seven invalid cases, no passing container evidence and no
container effect (`/tmp/jido-cluster-s6-docker-all-provider-unavailable.log`).
Changed local links, all 39 example pairs, all five explicit runner paths/tags,
and `git diff --check` pass. Core remains clean on `codex/v3-findings-core`.

Production compilation with warnings-as-errors and documentation generation also
pass (`/tmp/jido-cluster-s6-docker-all-provider-{prod,docs}.log`). No Mix process
remains active at this checkpoint. No commits, sibling source edits, Engine
restarts, or real container effects were made. The next implementation work is
the cumulative Docker runners in managed and attached Core modes, using the
existing complete shared lifecycle scenario and independent worker controls.

## S6 real-provider acceptance

On 2026-09-16, the local Docker Engine resumed responding without a restart.
The pinned Linux worker release built as image
`sha256:763a2867b42f799b9c05a10fc3c47951e37190e5f2d8bb778a706e242c138a7f`.
Five backend Docker cases and nine real provider example cases pass. The latter
include the full shared system scenario in managed and attached Core modes,
using three real containers, real Bedrock, borrowed retention, and exact final
deletion. No Cluster-labelled container remains. See the
[S6 audit](../06_host-providers/plan.md#real-docker-acceptance-and-s6-audit)
for case links, changes, and logs.

After the production HostWork fix, the default suite passes 371 tests with seed 0.
Quality, production compilation, and documentation generation pass. An isolated
consumer compiles and starts Cluster without Req or Bedrock. A dedicated Docker
CI job is configured but has no remote result because this worktree is unpushed.
S6 implementation and local acceptance are complete. S7 remains the active slice.

## S7 bounded entity acceptance

The [S7 implementation record](../07_entity-capabilities/plan.md#s7-implementation-and-acceptance)
maps eight entity requirements to code and executable tests. The
[entity facade](../../../lib/jido_cluster/entity.ex) maps a domain key and
definition ID to one versioned core Topology ID and Ref. One singleton
Topology per identity uses the existing scope service, shared admission,
journal, host claims, drain, and recovery. The supported scope has at most
eight running identities and 16 total deployment records. A stopped identity
stays in the journal and cannot be started again in that scope.

Four [numbered entity examples](../../../examples/10_entities/README.md) pass on
native peers. They cover simultaneous first calls, movement with retained Ref
and committed state, shared capacity with declared topology demand, and an
offline old-checkpoint import. The importer keeps the old source record and
requires stopped old writers and a stopped target Cluster. It is not a live
migration. Pending and uncertain results do not replay a Signal.

The focused entity command passes 13 tests with seed 0 and no failures
(`/tmp/jido-cluster-s7-focused.log`). The final `mix test.all` run passes
384 tests with seed 0 and no failures
(`/tmp/jido-cluster-s7-final-all.log`). `mix quality` passes for 189 modules,
with full Doctor documentation and spec coverage and no Credo issues. The
production warnings-as-errors compile and `mix docs` pass. The eight-entity
local Mnesia RAM benchmark reports 198.878 ms total, 21.276 ms median, and a
17,756-byte journal record against the 98,304-byte bound. This measurement
does not establish production throughput.

The final V3 Docker worker image is
`sha256:7bec0388115a6a38580569959edada31c3c2231ce739f98457f8dee5275a64d3`.
Five backend cases and nine provider examples pass against it, including both
managed and attached cumulative Core modes. No Cluster-labelled container
remains. These are S6 regression results after the S7 service changes; the S7
entity examples use native peers and shared Mnesia. No remote CI result exists
because this worktree is unpushed.

S1–S7 implementation and local acceptance pass for their stated bounds.
Design review remains `Pending approval`. No commit, push, CHANGELOG edit, or
sibling source edit was made for this work.
