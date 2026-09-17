# S3 — Durable operation records and recovery

Status: required S3 implementation and slice tests pass. The plan was written on
2026-09-15. Earlier appendices record intermediate states; the final promotion
record below is current. Review is Pending approval.
See [scope and dependencies](README.md).

## Outcome

Persist placement intent and reconcile interrupted operations through normal
core persistence adapters. Default to Bedrock with an application-owned Repo.

## Implementation steps

1. Write storage contract tests for CAS conflicts, indeterminate writes, and
   restart discovery through the public core Store boundary.
2. Implement `Journal` encoding and validation on `Jido.Persistence.Store`.
   Keep Agent checkpoint keys separate from journal keys.
3. Start with one versioned aggregate record per scope, updated through CAS. Store
   request bindings, active operations, claims, deployment definitions/references,
   desired revisions, and drain state together to avoid multi-key atomicity claims.
4. Put bounds on encoded size and retained completed requests. Reject new work
   before exceeding bounds. Never prune active or uncertain operations.
5. Record intent before side effects and confirmed results afterward. Mark unknown
   write outcomes uncertain and reread before taking another action.
6. On restart, validate the record, recover ownership, compare accepted core
   placements and live readiness, then enable admission only after reconciliation.
7. Add interrupted-drain examples and a real Bedrock integration test.

## Contracts and lifecycle

Use a stable versioned key derived from namespace and scope. Encode portable data,
not PIDs or functions. Include a schema version and reject unknown newer schemas.
The aggregate is a bounded first implementation; measure its size and write cost
before designing sharding or an index. Define and expose request-retention limits;
deduplication uses retained bindings, while expired request tokens are rejected
explicitly rather than treated as fresh operations.

Adapter options use `{Jido.Persistence.Bedrock, repo: MyApp.Repo}` by default.
Allow explicit supported overrides. A journal write does not grant writer authority.
Application-owned repositories start before Cluster. Attached core persistence is
never changed. Memory-only tests must opt in.

## Failure handling

- Missing backend or repository: fail configuration; no memory fallback.
- Journal unavailable: block mutations; report recovery status.
- CAS conflict: reread and reconcile; never overwrite another revision blindly.
- Unknown write result: inspect stored revision/request before repeating work.
- Unknown source state: keep its claims and operation uncertain.

## Tests and completion

Use fault-injected adapter tests and actual Bedrock tests. Run one alternative
core adapter through the same record suite. Test shared Repo key isolation, record
bounds, version rejection, and retention semantics. Kill the coordinator between
intent, movement, and completion writes; verify no duplicate activation or false
success after restart.

Done when partial drain and request lookup survive restart, backend failures block
unsafe work, and journal growth has an enforced bound.

Write the unit contracts first, then local peer tests, then the tagged living
example. Run relevant package format, compile, quality, and test checks. Record
actual results and evidence links here before marking this slice complete.

## Example-based acceptance plan

Status: planned examples; none are created or proved by this document. Follow the
[shared example test method](../00_architecture/example-testing.md).

Proposed group: `examples/06_journal_recovery/`, mirrored under
`test/examples/06_journal_recovery/`. These numbers extend the existing 01–03 groups;
confirm they remain free before implementation. Keep scenario IDs stable once added.

### Setup

Use a control process that can be killed and restarted while worker peers and
an application-owned Bedrock repository remain alive. Use unique scope keys for
each case. Store Agent checkpoints separately from journal records.

### Scenarios

| Proposed example | Actions | Required observations |
| --- | --- | --- |
| `06_01_interrupted_drain` | Move the first of two workers; pause before the second move, kill the coordinator, then restart with the same scope. | Accepted placement intent and committed state survive confirmed cleanup and reactivation. Remaining claims and drain intent are recovered. Work settles without duplicate activation or false success. |
| `06_02_unknown_write` | Use a test adapter wrapper that commits a journal write but loses its response; restart or reconcile. | The original request can be found by ID. No new operation is created to resolve the timeout; stored evidence determines the next step. |
| `06_03_uncertain_source` | Disconnect a source during a recorded move while leaving a spare host. | The operation and retained claims remain uncertain after restart. Spare capacity does not cause replacement. |
| `06_04_adapter_choice` | Run a normal deployment/stop cycle with Bedrock, then an explicitly configured alternative core adapter. | Both use isolated journal keys and preserve Agent records. Missing default backend configuration fails clearly; no memory fallback occurs. |

### Evidence and failure control

Start with coordinator-process failure; it is not a control-node or repository
failure proof. Add repository-unavailability variants in the adapter/peer suite.
Place barriers at journal or operation boundaries via test-only adapters/fixtures.
The unknown-write case must establish that storage changed before withholding the
reply. A wrapper exception before a write is a different failure.

The real Bedrock path is required for slice promotion. Report missing prerequisites
as unavailable evidence, not a successful fallback. Keep record-size, schema,
retention, and CAS-conflict edge cases in fast contract tests.

### Promotion record

For each scenario, add links to its source, README, and executable test. Record
the command, seed, backend, result, and cleanup result. Map every README guarantee
to an assertion. A fake-only result cannot prove an external backend contract.
Keep this slice incomplete until its required examples and lower-level contracts
pass; record unavailable cases explicitly.

## Cross-slice refinements

Use [the restart and retention contracts](../00_architecture/lifecycle-contracts.md).
A crash may terminate the old workers through confirmed owner cleanup. The
interrupted-drain test proves durable intent and restored state, not PID survival.
Add an explicit stopped-deployment restart case and a full service-shutdown case.
Keep control-node loss separate and uncertain.

Select and record numerical aggregate size, active operation, retention-epoch,
and deployment limits before implementation. Measure them against Bedrock limits.
The aggregate is an initial bounded representation, not a permanent public format.
Use expiry-aware request tokens or prove an equivalent bounded expiry protocol.
Expired requests return an explicit error rather than becoming new work. Preserve
active/uncertain bindings and reject new admission when retention cannot advance.

Add expiry replay, saturated retention, separate Agent/journal configuration, and
unrelated-progress-after-restart cases. Verify that durable journal configuration
alone never reports Agent state durability. Keep request identity compatible with
S1 by designing this protocol before finalizing its public API.

## Final build refinements

Treat reconciliation as the correctness path after abrupt death; termination
callbacks only accelerate cleanup. Record each external step before submitting it.
On uncertain results, inspect the original attempt before any candidate fallback.
Add generated replay/recovery sequences with repeated confirmations and writes;
compare accepted intent and claims against a small reference model.

## Decisions and limits

The aggregate-record proposal must fit backend value limits. Fix the concrete
limit and retention policy before implementation. No automatic cross-node takeover
or stale-writer fencing is included. A later multi-record design needs its own
atomicity and discovery proof.

## S3 implementation decisions

The current implementation uses the limits below. Earlier measurements in this
plan used the smaller initial bounds and remain historical evidence.
The scope aggregate uses JSON with a versioned header and an exact-byte CAS
condition or the opaque token returned by the adapter. Every successful write
advances its revision and records a new write ID. Stored data cannot construct
atoms, modules, PIDs, functions, or references.

- CL-JOURNAL-REQ-101: The journal shall reject an encoded record above 4194304 bytes before calling the adapter.
- CL-JOURNAL-REQ-102: The admission service shall reject new work whose candidate aggregate exceeds 4000000 bytes.
- CL-JOURNAL-REQ-103: The service shall limit each aggregate to 16 deployments, 32 hosts, 1024 claims, 16 unresolved operations, and 64 total request bindings per retention epoch.
- CL-JOURNAL-REQ-104: While a write result is unknown or conflicting, the journal shall reject another write through that handle until storage has been read again.
- CL-JOURNAL-REQ-105: Before recovery submits an external effect, the service shall confirm a new journal revision through CAS.
- CL-JOURNAL-REQ-106: When a durable deployment is encoded, the service shall resolve definition and input identifiers through the application-supplied trusted registry.

The hard byte limit leaves 32 KiB below the Bedrock adapter's 128 KiB ceiling.
The admission limit reserves another 32 KiB for bounded completion and recovery
metadata. Count limits are upper bounds; the byte limit can reject a smaller
aggregate with large definitions. Reasons stored in the aggregate will be bounded.
The binding limit includes accepted and uncertain work, so completion cannot
overflow the retained result limit. Only terminal request bindings can expire.
Epoch advance requires all bindings
in that epoch to have completed; unresolved bindings prevent expiry and can cause
explicit retention saturation. Old tokens will return an expiry error.

The storage contract suite will cover exact-byte and token CAS, conflicts,
committed writes with lost replies, delayed writes, record bounds, schema
rejection, and scope key isolation. Service and real Bedrock evidence remain
required before S3 completion.

## Storage and definition evidence

`Jido.Cluster.Journal` now stores a versioned JSON envelope through the core
adapter callbacks. The handle keeps exact read bytes or an opaque read token.
Unknown write results and conflicts block that handle until a reload. Reload
does not write or submit an external effect. A test delays the original CAS,
confirms a recovery revision, then proves the delayed write conflicts.

The journal rejects runtime values, non-string object keys, unsupported headers,
scope mismatches, and records above 4194304 bytes. The 4000000-byte admission limit
and aggregate count/retention limits are still service work, not enforced by
this storage component alone.

`Jido.Cluster.Journal.Definition` uses `Jido.Topology.Codec` with a trusted registry
supplied by the caller. It stores the original definition and portable input,
not the runtime plan. Tests restore atom-keyed input through stable IDs, reject
unknown Agent identifiers and runtime values, and reject malformed tagged input.
At this increment, the public instance configuration had not enabled the registry
option. The service integration below now uses it.

The shared record contract runs with the controlled adapter, real Mnesia
transactions, and a real Bedrock 0.7.2 repository with bedrock_raft 0.10.1. The
Bedrock test uses one isolated peer, local filesystem storage, and relaxed
durability. It checks CAS conflict, 25 further revisions, scope key isolation,
record-size rejection, preservation of an unrelated Agent key, repository
restart, and restored record equality. The peer and owned files are cleaned up.
The test does not skip and does not use the paused core Bedrock suite.

The final run measured 25 small-record Bedrock CAS writes in 19803 microseconds.
This is a fixture observation, not a throughput guarantee or aggregate-capacity
measurement. Full aggregate encoding and its size/CAS cost still need measurement.
Repository restart in one VM does not prove machine-loss or replicated durability.

Verification at the storage increment: `mise exec -- mix quality` passed, and `mise exec -- mix
test.all` passes 137 tests with seed 0. These results include the real Bedrock
test. Durable service integration, request expiry and saturation, coordinator
recovery, S3 living examples, and the cumulative examples remain incomplete.

## Retention and aggregate increment

The memory service now enforces the count limits and reports limits and retention
use through `status/1`. A full terminal epoch advances when a caller requests a
new token. The old tokens then return `:expired_request`, and old operation IDs
return `:not_found`. Live placements, claims, and stopped intent remain. An
uncertain operation prevents expiry; retained duplicate requests still resolve
at saturation. Tokens with extra fields or a non-integer epoch are rejected.
Stopped deployments count toward the 16-record limit; no forget API exists yet.

`test/jido_cluster/request_retention_test.exs` verifies these rules through the
facade and actual core Agents. It checks cleanup, retained PIDs and claims, a
killed operation task, and the deployment limit after 16 deploy/stop cycles.
The following service increment also persists these epochs.

`Jido.Cluster.Journal.Snapshot` now encodes the scope state. It stores trusted
definitions and input, generation and epoch, request fingerprints, operation and
attempt IDs, desired state, host inventory, allocation and incarnation, claims,
source exclusions, and complete drain transitions. The service retains each
step's selected hosts, arrivals, and retired Ref demand. Runtime PIDs, tasks,
waiters, and expanded plans do not enter the record. Reasons have a 512-byte cap
and restore as observation text. They do not select recovery actions.

The reader resolves node names only from configured hosts. It rejects changed
budgets, unknown definitions or Refs, duplicate identities, missing placement
claims, repeated Ref reservations, unsupported fields, and count violations.
The encoder applies the 4000000-byte admission limit and 4194304-byte observation
limit with reserved envelope space. Portable fingerprints exclude the expanded
runtime plan. The following service increment connects both contracts.

The aggregate fixture has 16 deployments, 32 source and target claims, 64 request
bindings, and one drain with 16 pending moves. Real Mnesia and Bedrock both run
25 conditional writes and restore the record. The Bedrock repository restart
test also checks this aggregate. Its measured envelope size is 47199 bytes; the
first focused run took 49575 microseconds for 25 writes. This fixture measures
storage of intent. It does not execute those 16 deployments or prove coordinator
recovery. Different definitions can reach the byte limit before a count limit.

The journal rejects a known revision that moves backward, or a known revision
whose write ID or record changes. A fresh handle has no prior history, so this
check does not prove that a backend has preserved every past committed revision.

The focused local tests pass, the shared drain peer test passes, and the real
Bedrock aggregate/repository test passes. `mix quality` passes. The isolated
`mix test.all` run passes 151 tests with seed 0 in 52.2 seconds. In that final run,
the 25 aggregate CAS writes took 47009 microseconds. These measurements describe
this single-node fixture and are not a throughput or machine-loss guarantee.
S3 remains incomplete until recovery and its examples pass.
Review status remains Pending approval.

## Service write integration

The named service now accepts a core journal adapter and an explicit `registry`.
The default remains Bedrock with application-owned Repo configuration; no memory
fallback exists. `agent_persistence` remains a separate managed-core option.

`Instance.Store` loads and validates the record and confirms a new CAS revision
at startup. Each admitted deployment, stop, drain, and host-enable request is
stored before acknowledgement or task start. Host incarnation binding, each
confirmed move, completion, and epoch advance also pass through the journal.
The service uses portable request fingerprints and aggregate byte/count bounds.
Operation callbacks use the original service PID, so an old task cannot call a
replacement authority through its reused module name.

An unknown or conflicting write blocks mutations with `:journal_unavailable`.
The service retains the prior state and candidate separately; public claims
include both possible sets. Thus an uncertain stop completion cannot free
capacity in memory. An explicit pre-write rejection at admission can be retried.
Completion is not returned until its record is confirmed. A restart reads the
original request binding, including a write whose reply was lost.

The service can restart after confirmed stop and retain stopped intent, operation
results, generation, and epoch. Running or unfinished records currently block
mutation with `:reconciliation_required`. Stored completion is historical evidence;
it does not establish current Agent readiness. The implementation has no in-place
reconcile API yet. Use of exact prior-attempt cleanup receipts, retained host adoption,
running-intent recovery, and independent progress after restart remain required.

`test/jido_cluster/journal_service_test.exs` uses controlled write barriers to
prove that admission precedes activation and stopped intent precedes cleanup.
It covers missing registry, unknown acceptance and completion, confirmed
pre-write rejection, CAS conflict, byte rejection, epoch expiry after restart,
and claim retention after a lost stop completion. An unfinished empty drain
also blocks restart even though it has no claims.

`test/support/journal_service.ex` runs the actual deploy/work/stop/service-restart
cycle with real Bedrock and Mnesia. Agent persistence uses the same adapter in
that fixture; an unrelated Agent key remains unchanged. Both backend tests pass.
The shared-drain peer test now runs in both memory and journal modes and checks
two movements, stable Refs, retained committed Agent state, and cleanup.

Quality checks pass. The isolated `mise exec -- mix test.all` run passes 163 tests
with seed 0 in 59.6 seconds. These results do not prove running-intent or partial-drain
recovery, the S3 living examples, or the later slices.

## Activation identity and cleanup evidence

Each deployment now has a separate activation record with an ID, control node,
control-runtime ID, namespace, scope, and topology ID. The journal stores it before
activation. Request-epoch expiry retains it. `status/2` exposes this identity
separately from the latest operation ID.

`Jido.Cluster.Activation` retains one local evidence record per scope and topology.
The Scheduler owner claims the exact activation before creating a Controller.
Only that owner process can record settlement, after operation cancellation, core
cleanup, and Controller child exits are confirmed. A new attempt can replace a
settled record. It cannot replace an uncertain record or reopen a settled attempt.

The evidence process outlives named service shutdown. If the evidence process or
control runtime restarts, its runtime ID changes. This cannot authorize recovery
from the old record. Owner death, missing evidence, and a changed attempt report
uncertainty. This is not a disk receipt or a VM-loss proof. Legacy standalone
Schedulers do not use this managed activation record.

`test/jido_cluster/activation_test.exs` checks exact identity, owner-only settlement,
replacement exclusion, owner death, malformed input, and changed runtime. Its
real Agent case kills a Scheduler owner and waits for the directory entry to
disappear; cleanup still reports unconfirmed. The service test confirms settlement
after full named-service shutdown while the journal retains running intent. The
retention test confirms that activation evidence survives operation expiry.

A restart test also found a host-guard attachment race. When a former core has
stopped, attachment now waits for that guard's monitored exit and makes one bounded
retry. It does not replace a guard whose original core is still alive. The test
suspends the old guard, observes the queued public attachment call through OTP
message tracing, then resumes it. The prior implementation failed this case.

These contracts provide recovery evidence; they do not yet reactivate a running
deployment. Host claim adoption, maintenance progress, and in-place journal
reconciliation remain S3 work. Full-suite evidence is recorded in the implementation
state. The isolated `mise exec -- mix test.all` run passes 170 tests with seed 0
in 58.8 seconds. Quality checks pass. The Bedrock aggregate with activation
identities is 50950 bytes; its 25 CAS writes took 53384 microseconds in that run.
Review status remains Pending approval.

## Explicit recovery increment

`Jido.Cluster.reconcile/1` now rereads the journal and confirms a new CAS revision
before external recovery work. It returns after starting a bounded pass. The
service reports `recovering`; each deployment reports `:recovering`, `:ready`, or
`:uncertain`. Existing accepted work prevents a concurrent pass. A healthy service
needs no replacement when reconciliation is repeated.

The pass first settles the exact prior activation. It checks direct host release,
persistence identity, Agent modules, allocation, and retained claims. It records
the current host incarnation before reopening that guard. A replacement attempt
and its complete retained reservation are stored before host confirmation or
Controller startup. Unknown writes block further effects. Failure retains the
claims of the affected deployment. Independent hosts can recover and serve work.

Activation records now include an increasing sequence number. An unused attempt
is closed atomically in the same runtime. A delayed owner cannot reopen it or an
older attempt after a later one settles. Owner death without confirmed cleanup
still cannot authorize replacement. Runtime loss remains outside this proof.

The journal also retains the original selected definition. Core requires it to
validate its saved target after movement. Recovery keeps both source and target
claims for unfinished moves until Core reports target readiness and source
release is confirmed. A partial drain resumes the same parent request and retains
confirmed historical step results. Historical completion alone cannot complete
a parent whose current recovery is uncertain.

Current limit: a moved deployment requires Core persistence for its accepted
target record. With no Agent persistence, recovery returns
`:placement_restore_requires_persistence` and retains claims. The journal does
not replace Core's target store. No Cluster code decodes or changes Core records.
This conservative limit needs a public Core contract review before broader
volatile-target recovery can be claimed.

Evidence in this increment:

- [Activation tests](../../../test/jido_cluster/activation_test.exs) cover closure
  of unused attempts and rejection of delayed owners.
- [Recovery tests](../../../test/jido_cluster/recovery_test.exs) cover saved Agent
  state, request expiry, lost acceptance, host-binding and completion replies,
  and host-guard restart with a new incarnation.
- [Shared drain tests](../../../test/jido_cluster/distributed/shared_drain_test.exs)
  kill the coordinator after one recorded movement and before an unstarted second
  movement. They check original requests, state, Refs, claims, and cleanup. A
  separate case checks the missing Core persistence limit.
- [Independent progress tests](../../../test/jido_cluster/distributed/independent_progress_test.exs)
  retain an uncertain movement after owner death and service restart while an
  independent deployment returns to ready. A second case makes the recorded
  source unavailable and verifies both claims remain charged and no target
  replacement starts. The fixture stops a peer; this is not a live partition test.
- [The backend service contract](../../../test/support/journal_service.ex) now
  restores running intent and committed Agent state with real Bedrock and Mnesia,
  then verifies stop and stopped-intent restart. The Bedrock fixture remains one
  peer with relaxed local filesystem durability.

Quality checks pass. The isolated `mise exec -- mix test.all` run passes 185 tests
with seed 0 in 61.9 seconds. Full-suite evidence is kept in the
[implementation state](../00_architecture/implementation-state.md). The recovery
suite also runs three generated 32-event histories against a
small reference model. It checks committed counts and revisions, original request
bindings, desired state, and one active claim after each event. The full suite includes
these generated cases and the unavailable-source case. Interrupted recovery at
journal boundaries, the four S3 living examples, and cumulative examples remain
unfinished. S3 and the seven-slice goal remain incomplete.
Review status remains Pending approval.

## S3 promotion evidence

All required S3 scenarios pass in `mise exec -- mix test.all`, seed 0: 193 tests,
zero failures, 73.9 seconds. Quality checks pass. This establishes the bounded S3
contract described above. It does not complete S4–S7 or the cumulative examples.
Earlier statements about missing reconciliation or examples describe prior states.

| Scenario | Source and explanation | Executable proof |
| --- | --- | --- |
| Interrupted drain | [README](../../../examples/06_journal_recovery/06_01_interrupted_drain/README.md), [topology](../../../examples/06_journal_recovery/06_01_interrupted_drain/topology.ex) | [Test](../../../test/examples/06_journal_recovery/06_01_interrupted_drain/interrupted_drain_test.exs) |
| Committed write with lost reply | [README](../../../examples/06_journal_recovery/06_02_unknown_write/README.md), [topology](../../../examples/06_journal_recovery/06_02_unknown_write/topology.ex) | [Test](../../../test/examples/06_journal_recovery/06_02_unknown_write/unknown_write_test.exs) |
| Live source partition | [README](../../../examples/06_journal_recovery/06_03_uncertain_source/README.md), [topology](../../../examples/06_journal_recovery/06_03_uncertain_source/topology.ex) | [Test](../../../test/examples/06_journal_recovery/06_03_uncertain_source/uncertain_source_test.exs) |
| Adapter choice | [README](../../../examples/06_journal_recovery/06_04_adapter_choice/README.md), [topology](../../../examples/06_journal_recovery/06_04_adapter_choice/topology.ex) | [Tests](../../../test/examples/06_journal_recovery/06_04_adapter_choice/adapter_choice_test.exs) |

The examples use real Bedrock on the control peer and separate shared Mnesia Agent
storage. The adapter-choice example also uses Mnesia for the journal and rejects
missing default Repo configuration before startup. Checked fixture cleanup stops
owned peers and removes the owned Bedrock directory. No example uses a fallback
backend or a skipped result as evidence.

The partial-drain barrier holds the journal reply after the first move is stored
and before the second move starts. Direct journal inspection proves one completed
step and three retained claims before the service dies. Restart preserves the
parent request, Refs, committed state, and both required movements.

The partition case leaves the original source Agent alive. Restart retains both
claims and an uncertain operation; the target has no Agent. Reconnection permits
explicit recovery. This test exposed premature Controller cleanup: Core cleanup
could report success while a remote host was unreachable. Cluster now checks all
known source and target hosts before and after cleanup. It retains the Controller
and activation evidence while those hosts are unreachable. This is a connected
recovery guard, not a lease or partition-safe writer fencing mechanism.

[Recovery tests](../../../test/jido_cluster/recovery_test.exs) also interrupt the
host-adoption and replacement-intent journal writes. Delayed replies cannot act
through a replacement service. The same request returns with one ready Agent,
one active claim, and the committed count and revision.

[The real Bedrock test](../../../test/jido_cluster/distributed/journal_bedrock_test.exs)
stops the Repo while the service and Agent remain alive. Journal mutations fail,
claims remain charged, and lookup reports uncertainty. Repo restart and explicit
reconciliation restore the committed state; the original retry token is retained.
Mnesia and Bedrock both pass the common record and service contracts. The existing
size, schema, CAS, retention, generated-history, and independent-progress tests
remain in the full suite.

The limits remain explicit: one control runtime, no automatic cross-node takeover,
no disk cleanup receipt, bounded aggregate and request retention, and separate
Agent persistence. Moved-target recovery requires Core persistence. Bedrock tests
use a single peer with relaxed filesystem durability. Machine failure, replica
failure, and later cumulative system behavior are not proved here.

## Core Store integration — 2026-09-16

The journal now opens, reads, and conditionally writes through the public
`Jido.Persistence.Store` API. Core owns byte-adapter validation, callback fault
containment, exact-byte or token conditions, generic write classification, and
storage telemetry. Cluster keeps its scope key, JSON format, size bounds,
revision and write-ID checks, and external-effect recovery rules.

The explicit journal requires `Store.open/1`; memory remains opt-in. Optional
Agent persistence still resolves through public `Jido.Persistence.resolve_config/2`.
Both forms of indeterminate results retain an uncertain handle. Only an explicit
pre-write rejection leaves the journal handle writable. Conflicts still block
that handle until reconciliation. No Store condition grants activation authority.

The duplicate Cluster Mnesia adapter and its byte-only unit suite are removed.
Current runtime fixtures, guides, benchmark, and Docker worker use
`Jido.Persistence.Mnesia` from the local core package. Existing record bytes and
scope keys are unchanged. Core owns adapter tests, including a disk-copy restart;
Cluster retains the real Mnesia journal and service recovery contracts.

[Store integration tests](../../../test/jido_cluster/journal_store_test.exs)
prove telemetry use and redaction, exact read-byte retention, malformed reads,
callback faults, unconfigured-store rejection, and committed plain-indeterminate
write discovery without replay. Existing token, conflict, delayed-write, revision,
Bedrock, and multi-node recovery tests remain required.

Validation after integration: 19 selected core Store/adapter/Mnesia tests pass,
including the Mnesia disk-copy restart. Cluster's full suite passes 343 tests,
seed 0, with zero failures. Five real Docker backend tests and nine Docker
examples pass with the rebuilt worker; no Cluster-labelled containers remain.
The image is `sha256:cc621b3b214d57cdf8a6da0879f2fa3a1f4da175fe5a9b4e235f67a9bffefcd4`.
Quality and documentation generation pass. Logs are under
`/tmp/cluster-persistence-{core-tests,all,docker,docker-examples,quality,docs}.log`.
These results establish the existing bounded recovery contracts; the shared Store
does not add leases, transactions across records, or automatic host replacement.
