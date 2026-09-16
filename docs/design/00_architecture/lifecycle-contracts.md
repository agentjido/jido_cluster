# Shared lifecycle and failure contracts

Status: direction accepted in discussion on 2026-09-15; detailed contracts below
are proposed requirements pending implementation evidence and document review.
This document resolves the cross-slice questions from the holistic review.

## Ownership and restart

A deployment has durable desired state, a placement coordinator, and a core
Controller. Those are separate lifetimes. The first release retains confirmed
cleanup after coordinator failure. It does not promise uninterrupted workers.

| Event | Desired state | Runtime response | Recovery boundary |
| --- | --- | --- | --- |
| Explicit deployment stop | Record stopped before cleanup | Retire its Agents and bindings; release only its unused capacity | Do not reactivate stopped intent |
| Orderly Cluster service shutdown | Preserve deployment intent | Clean up owned Controllers, Agents, and bindings | A later start reconciles running intent |
| Deployment coordinator crash | Preserve intent and operation progress | Existing owner settles core cleanup | Reactivate only after confirmed cleanup |
| Control-node disconnect/loss | Preserve last durable evidence | Remote effects may still exist | No timeout-based takeover or replacement |
| Attached core loss | Preserve intent | Block dependent mutations and reconcile cleanup | Resume only with compatible core and settled ownership |

An orderly stop can fail to finish cleanup; process termination itself cannot
prove that remote resources are gone. Keep durable release work discoverable.
Shared and acquired hosts remain claim-accounted until cleanup is established.
Operator reconciliation inspects evidence; it is not a force-retirement mechanism.

- CL-LIFE-REQ-001: When a deployment stop is accepted, the deployment owner shall record stopped intent before submitting cleanup.
- CL-LIFE-REQ-002: When a coordinator crashes, the deployment owner shall require confirmed prior cleanup before reactivation.
- CL-LIFE-REQ-003: If source retirement is unconfirmed, then the placement owner shall report uncertainty.
- CL-LIFE-REQ-004: When the Cluster service shuts down, the journal shall retain unfinished cleanup records.

Evidence: S1 managed/attached lifecycle cases; S3 interrupted drain and stopped
intent restart variants; the cumulative scenario below. S1 memory mode cannot
provide durable intent across full service restart and must expose that limit.

## Capacity scope and reservations

One physical managed host budget belongs to one stable scope. Pool names select
from that inventory; aliases never create capacity. Explicit budget partitions
need their own stable allocation IDs and limits. A HostSession registration binds
the host incarnation and allocation to its connected scope owner. Conflicting
registrations in the supported connected view fail.

This check does not discover every unmanaged process or protect against another
network partition. The old Scheduler and keyed manager remain outside managed
accounting. Configuration must reject known overlap; deployment documentation
must reserve disjoint budgets for unmanaged or legacy consumers. Do not claim
host-wide enforcement against arbitrary external processes.

A mutation declares its affected deployments, host allocations, and claims. The
admission owner serializes ledger changes. Bounded operation tasks execute work
using those claims. A long-running task must not hold the admission GenServer call.

- CL-CAP-REQ-001: If a host allocation is registered to another connected scope owner, then host registration shall reject the conflicting claim.
- CL-CAP-REQ-002: When pool aliases name the same host allocation, admission shall count its slots once.
- CL-CAP-REQ-003: If an operation becomes uncertain, then admission shall retain its unresolved resource claims.
- CL-CAP-REQ-004: When an operation becomes uncertain, the operation scheduler shall release its execution slot.
- CL-CAP-REQ-005: While an operation is uncertain, admission shall allow otherwise admissible requests that do not conflict with its retained resources.

Start with one executing placement operation per scope if useful, but distinguish
execution slots from retained claims. An uncertain operation is parked. A new
request touching a blocked deployment or allocation is rejected with conflict
identifiers. A request on independent capacity can proceed. Journal unavailability
blocks all mutations because the scope ledger itself is unavailable.

Evidence: S2 alias/conflicting-registration tests and an uncertain drain on pool A
while a deployment on disjoint pool B completes. S3 repeats that case after restart.

## Journal bounds and request identity

The scope aggregate is an initial implementation, not a public storage format.
Measure encoded state and CAS cost before selecting a supported deployment count.
S3 must choose numerical record, active-operation, and retained-request limits
that fit the selected adapter. No default scale claim exists before that proof.

Use opaque generated request tokens that include a scope generation and bounded
retention epoch, or another equally testable expiry scheme. The first detailed
implementation must choose the encoding. Do not allow arbitrary old IDs to be
silently treated as new after pruning. API compatibility with earlier string-ID
sketches must be recorded before implementation.

- CL-REC-REQ-001: If a journal update exceeds the configured record budget, then the journal shall reject the update before side effects.
- CL-REC-REQ-002: While an operation is active or uncertain, the journal shall retain its request binding.
- CL-REC-REQ-003: If a submitted request token belongs to an expired retention epoch, then the operation API shall return an expired-request error.
- CL-REC-REQ-004: If a journal write result is indeterminate, then the journal coordinator shall reconcile stored evidence before submitting another dependent side effect.
- CL-REC-REQ-005: The instance configuration shall expose Agent persistence separately from journal persistence.

Retiring an epoch requires all its active/uncertain requests to settle; cap the
number of retained epochs and reject new admission if that budget is exhausted.
This retains a bounded rejection watermark without keeping every completed ID.
Journal durability never implies Agent checkpoint durability or writer fencing.

Evidence: S3 record-bound, epoch-expiry, retained-uncertainty, separate-storage,
and unknown-write tests. Keep backend layout replaceable behind the journal API.

## Readiness and federation bounds

Status exposes independent observations: Agent readiness from core, required
binding readiness, transport/bridge health, and operation state. Initial deployment
completion requires core readiness and confirmed required local bindings. It does
not promise live connectivity to every publisher. Report degraded transport beside
that completion. Loss of a required binding changes current deployment readiness;
it does not rewrite a historically completed operation.

- CL-READY-REQ-001: When a deployment completes activation, its status shall expose Agent readiness and binding readiness separately.
- CL-READY-REQ-002: While a required binding is unattached, the deployment shall not report current full readiness.
- CL-READY-REQ-003: If federation transport disconnects, then federation status shall report degradation independently of Agent readiness.

Only explicit federation publications cross hosts in the first mode. Ordinary
local Bus publication retains local semantics. A successful receipt establishes
local acceptance and bounded outbound submission, not remote execution.

- CL-QUEUE-REQ-001: If publication capacity is unavailable, then the publication API shall reject before local append.
- CL-QUEUE-REQ-002: If an envelope exceeds the configured payload limit, then the bridge shall reject it before queue admission.
- CL-QUEUE-REQ-003: If inbound bridge capacity is exhausted, then the bridge shall apply its documented drop or rejection policy and record the outcome.

S4 must specify numerical queue/payload limits, concurrent publisher admission,
transport buffering, inbound credits or equivalent admission, and per-host fanout.
A bounded GenServer queue does not bound that process's mailbox. The implementation
must prove where data stops entering. Application Agent mailboxes remain outside
this infrastructure bound and must be named as such. A source may only know that
delivery became uncertain, not the exact number of remote losses.

Evidence: S4 concurrent publication saturation and receive-side overload;
S5 binding loss, movement gaps, and bridge-only disconnect status.

## Host runtime contract before providers

A host runtime entry point starts or attaches to compatible core, registers a
host incarnation and capacity allocation, and owns its local federation resources.
Registration supplies host/provider identity, protocol version, namespace, release
identity, required Agent modules, persistence configuration identity, and available
services. Exchange configuration identities, not credentials. Verify facts with a
bounded direct probe before admitting new work.

- CL-BOOT-REQ-001: If registration has incompatible namespace or protocol version, then host admission shall reject it before Agent activation.
- CL-BOOT-REQ-002: When a host runtime restarts, registration shall identify a new runtime incarnation.
- CL-BOOT-REQ-003: If a host loses its control connection, then the host runtime shall reject new control mutations until registration is reconciled.
- CL-BOOT-REQ-004: When a disconnected host rejoins, the coordinator shall reconcile existing activations before granting new claims.
- CL-BOOT-REQ-005: If direct host evidence and the current journal exclude prior allocation claims, then host confirmation shall reconcile the empty allocation before confirming new reservations.

Requirement 005 is implemented by the exact empty-set HostRuntime reconciliation
call. Matching incarnation, scope, and capacity are required. Every journal claim
on that host must be reserved with no bound host incarnation. The attached-Core
recovery regression and static cumulative test cover reuse after owner loss.
The existing recovery path still owns all bound and uncertain claims.

Existing Agents are not declared dead on disconnect. Journal-controlled host
release still waits for cleanup evidence. The first mode assumes trusted connected
BEAM hosts; registration is not an isolation boundary against malicious peers.
S1 defines and tests this handshake on local peers. S6 supplies provider resources
that satisfy it. Provider acquisition must not introduce a second boot protocol.

## Early entity mapping probe

Before S2/S3 schemas become fixed, run a bounded design probe for a domain key
inside a core-defined workload. Compare supported topology expansion/activation
seams against the actual core code. Specify the Ref and persistence mapping,
activation owner, and claim granularity. No entity implementation is promoted here.

- CL-MAP-REQ-001: When an entity activation is admitted, the entity mapping shall identify its owning core workload and placement owner.
- CL-MAP-REQ-002: When the same supported entity key is restored, the mapping shall preserve its core Ref and persistence identity.

Evidence: S7 identity fixtures and a pre-S2/S3 design probe. If core lacks the
required seam, record the exact gap and keep fixed-singleton scope explicit.

## Cumulative system example

[11_01 Deployment lifecycle](../../../examples/11_system/11_01_deployment_lifecycle/README.md)
now implements the static scenario, with matching tests under `test/examples/`.
It uses ordinary non-AI Agents and stable IDs. The provider variant remains S6 work.

1. Start configured core and Cluster with Bedrock journal and explicit Agent
   persistence. Register three static worker hosts and two independent allocations.
2. Deploy two topologies sharing capacity, each with a declared subscriber. Publish
   a baseline event and inspect committed Agent state through public APIs.
3. Drain a shared source. After one move settles, interrupt the coordinator before
   the next move. Record actual Agent exits; do not assume worker continuity.
4. Restart and reconcile. Verify accepted placement, retained state, pending claims,
   and bindings. Confirm a previously stopped deployment stays stopped.
5. Disconnect a remaining source so its operation is uncertain. Verify admission
   can deploy unrelated work on the independent allocation without reclaiming the
   uncertain source's slots.
6. Restore reachability and explicitly reconcile. Verify current binding readiness,
   publish a fresh event, and inspect only the promised best-effort result.
7. Stop deployments and then Cluster. Verify process cleanup, retained external
   core in attached mode, and no remaining owned resources reported as settled.
8. After S6, run a provider-backed variant and verify actual owned resource release.

Use test-only barriers at operation, journal, and transport boundaries. Run managed
and attached core variants, but do not duplicate every fault permutation. Link each
phase to its slice's lower-level tests. Record seeds, backend, command, observations,
and cleanup. S5 promotion requires the static variant; S6 requires the real-provider
variant. The static test passes in managed and attached modes with real Bedrock
and shared Mnesia. It checks delayed target visibility, actual Agent cleanup,
partial-drain restart, retained stopped intent, independent progress during a
live-source disconnect, and final cleanup. See the
[S5 evidence](../05_federation-lifecycle/plan.md#static-cumulative-proof-and-final-failure-audit).

## Final refinements from Hyper review

The [pinned Hyper source review](../90_reference/04_hyper/README.md) motivates
these Cluster-specific requirements. They extend the existing admission and
cleanup contract; they do not adopt Hyper's runtime or dependencies.

- CL-ADMIT-REQ-001: Before initial Agent activation, admission shall reserve the complete supported topology demand.
- CL-ADMIT-REQ-002: Before accepting an activation request, the host runtime shall validate the current incarnation and scope claim identity.
- CL-ADMIT-REQ-003: If an activation result is unknown, then placement shall reconcile that attempt before selecting another host for the same demand.
- CL-ADMIT-REQ-004: If a local claim guard loses its state, then the host runtime shall block new activation until claim reconciliation completes.
- CL-CLEAN-REQ-001: When release is requested, reconciliation shall verify owned resource identity and incarnation before destructive cleanup.
- CL-CLEAN-REQ-002: If a resource observation is unavailable or conflicts with retained claims, then reconciliation shall retain the resource as uncertain.
- CL-CLEAN-REQ-003: When a stopped deployment is reconciled, its owner shall preserve stopped intent rather than reactivate it.
- CL-OBS-REQ-001: If location registration is pending, then the directory shall report a pending observation rather than authorize duplicate activation.
- CL-OBS-REQ-002: When an operation changes phase, its status shall expose the operation ID, attempt ID, affected resource identities, phase, and reason.

Scope admission remains the single ledger authority. A host guard validates its
allocation and the same stable claims; it does not create another reservation
budget or choose alternative placement. Before S2 implementation, define the
idempotent confirmation/inspection protocol and reconciliation after guard restart.

Provider inspection must distinguish not-found evidence from unavailable results.
For S6, add bounded owned-resource discovery when supported, using persisted step
IDs and provider ownership labels. Unexpected resources are candidates for review;
a label or two missing heartbeats alone never authorizes deletion. If discovery
is unsupported, state the recovery limit and retain explicit step-ID inspection.

Use structured status and telemetry at admission, activation, reconciliation, and
release boundaries. Include namespace, scope, topology, operation, attempt, claim,
and host-incarnation identifiers where applicable. Do not log credentials or Agent
payloads. Persistent facts and volatile measurements remain separate.

Evidence: S2 stale-candidate/host-guard tests; S3 unknown-effect and stopped-intent
restart cases; S6 abrupt-death resource reconciliation; generated pure-model tests
for claim conservation and cleanup exclusions. These are build gates, not results.
