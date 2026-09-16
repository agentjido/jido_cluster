# S4 — Scoped federated channels

Status: static-host implementation and acceptance checks pass. The final audit
below maps each S4 requirement and example to executable evidence. Review remains
Pending approval. S5 still owns movement and restart reconciliation. See
[scope and dependencies](README.md).

## Outcome

Declare channels and Agent subscriptions through core topology extensions.
Forward selected events between local Buses on static hosts in best-effort mode.

## Implementation steps

1. Add pure extension tests for channel names, allowed types, Ref targets, and
   namespace/topology scoping. Lower metadata without starting resources.
2. Add a small transport behaviour and a fault-injected test transport. Use a
   connected-BEAM transport for the first implementation; keep it replaceable.
3. Add host-local channel supervision, mirror Buses, and bounded bridges. Track
   interested hosts and attach declared subscribers after core Agent readiness.
4. Define a transport envelope with channel scope, origin generation, export ID,
   and hop bound while preserving the original Signal envelope.
5. Reserve outbound queue capacity before local append. Append failure releases
   the reservation and sends nothing. Submit after append; report subsequent loss.
6. Export only explicit federation publications. Never re-export imported events.
   Add bounded duplicate suppression and reject invalid scope or envelope size.
7. Add publish and federation-status APIs plus a three-host example.

## Contracts and lifecycle

Channel identity is namespace, topology ID, and channel key. A binding targets a
managed core Ref. Required attachment contributes to deployment readiness; it does
not prove that a remote event will be consumed.

A publication receipt means local acceptance and bounded outbound submission.
No global order, durable queue, remote execution acknowledgement, or automatic
business replay is promised. Transport queue bounds do not bound Agent mailboxes.
Keep payload limits, queue limits, and duplicate-cache retention configurable and
validated. Persist declarations through S3, not event payloads.

## Failure handling

- Invalid scope or full outbound queue: reject before local append.
- Local append failure: transmit nothing.
- Transport failure after acceptance: expose drops/degradation; no rollback claim.
- Required subscription attachment fails: deployment is not fully ready.
- Duplicate export: suppress only within the stated cache lifetime.

## Tests and completion

Prove A-to-B delivery, no local delivery on uninterested C, namespace isolation,
original Signal preservation, no loops, queue limits, and attachment failure.
Use explicit barriers for negative delivery assertions rather than arbitrary sleeps.
Compile and test the base package without optional transport dependencies.

Done when the three-host example passes and receipt, ordering, and loss semantics
are documented and tested.

Write the unit contracts first, then local peer tests, then the tagged living
example. Run relevant package format, compile, quality, and test checks. Record
actual results and evidence links here before marking this slice complete.

## Example-based acceptance plan

Status: the three planned examples now exist and pass their focused run. Follow
the [shared example test method](../00_architecture/example-testing.md).

The group is [07 Federation](../../../examples/07_federation/README.md), mirrored
under `test/examples/07_federation/`. Scenario IDs are retained from this plan.

### Setup

Use three peers: A publishes, B has a declared subscribing Agent, and C has no
interest. Add a second deployment with the same channel key to test isolation.
Agents record original Signal IDs and selected payload fields through normal
Signal handlers.

### Scenarios

| Example | Actions | Required observations |
| --- | --- | --- |
| `07_01_interested_hosts` | Deploy channels and bindings, await readiness, publish on A, and inspect B and C. | B commits the original event once within the normal path. No export targets C. The other deployment receives nothing. |
| `07_02_envelope_and_loops` | Connect bidirectional bridges; send a known export again with the same export identity. | Original Signal ID, type, source, and payload survive. Imported events are not re-exported. Duplicate suppression holds within its stated window. |
| `07_03_bounded_publication` | Hold transport submission, fill the bridge queue, and attempt one more publication. | The extra publication is rejected before local append. Releasing the barrier drains accepted work. A later transport failure is visible as loss/degradation, not rollback. |

### Evidence and failure control

Use a recording transport and explicit submission/receive barriers to prove
uninterested routing and loop bounds. A timed sleep plus no mailbox message is
not sufficient negative evidence. End the observed export batch before checking
counts. Test cache expiry separately; never turn the within-window duplicate
assertion into an exactly-once claim. Include a real connected transport path as
well as the fault-injected path.

### Promotion record

For each scenario, add links to its source, README, and executable test. Record
the command, seed, backend, result, and cleanup result. Map every README guarantee
to an assertion. A fake-only result cannot prove an external backend contract.
Keep this slice incomplete until its required examples and lower-level contracts
pass; record unavailable cases explicitly.

## Cross-slice refinements

Use [the readiness and queue contracts](../00_architecture/lifecycle-contracts.md).
Status separates Agent readiness, required binding readiness, federation health,
and operation state. Initial completion requires core and binding readiness;
transport health remains an explicit observation without a delivery promise.
Ordinary local Bus publishes are not automatically federated.

Before selecting the connected transport, specify publication admission, outbound
queue slots/bytes, inbound capacity, transport buffering, and fanout bounds.
Reject oversized envelopes before queueing. A bridge GenServer's own bounded data
structure does not bound its mailbox. Prove the ingress mechanism with concurrent
publishers and receive-side overload. Document remaining unbounded application
mailboxes rather than implying end-to-end backpressure.

Extend `07_03_bounded_publication` with concurrent senders and an overloaded remote
receiver. Report loss or uncertainty at the boundary that can actually observe it;
do not invent an exact remote drop count after disconnect.

## Final build refinements

Keep high-frequency bridge metrics and host observations out of the journal's
mutation path. Persist lifecycle facts only. Add public phase/reason observations
with correlated operation and host identity so fault examples need no private
process inspection. A missing location report is pending/uncertain evidence, not
permission to attach or activate another Agent.

## Decisions and limits

Confirm the selected transport's bounded submission mechanics during implementation.
Do not bypass core's remote-Agent/local-Bus rejection. If a generic Signal contract
is missing, demonstrate it in an integration test before changing that package.

## S4 declaration and capacity decisions

Version 1 metadata uses `jido.cluster.federation` with string keys and an explicit
version. `federated_channel` is a resource-section entity with a channel key and
exact allowed types. `federated_subscribe` is a connection-section entity with a
root Agent key, channel key, and `required` flag (default true). Lowering writes
metadata only. It does not add core Bus subscriptions to remote Agents. Group
and included-topology bindings remain outside the current root singleton scope.
The journal's normal core-definition codec preserves these declarations.

- CL-FEDERATION-REQ-101: The declaration validator shall reject more than eight channels, 32 types per channel, or 64 bindings per topology.
- CL-FEDERATION-REQ-102: The declaration resolver shall identify a channel by the exact namespace, topology ID, and channel key tuple.
- CL-FEDERATION-REQ-103: The declaration resolver shall resolve each binding to the core Ref of its named root Agent.
- CL-FEDERATION-REQ-104: If a channel, type, or binding is invalid or duplicated, then declaration validation shall reject it before resource startup.
- CL-FEDERATION-REQ-105: The envelope validator shall preserve the original Signal and reject a hop count other than one.

Channel keys use 1–128 UTF-8 bytes. Allowed types use 1–255 bytes, with
ASCII letters, digits, underscore, or hyphen in dot-separated segments. These
are exact types, not wildcard patterns. A binding receives each allowed channel
type. Signal ID and export ID are separate: a repeated explicit publication gets
a new export ID; retransmission of one export retains that export's identity.
Connected BEAM terms preserve atom keys and binary data without JSON conversion.
Runtime payload values such as PIDs and functions are rejected.

The default per-mirror budgets are:

| Limit | Default | Maximum configurable value |
| --- | --- | --- |
| Complete uncompressed envelope | 16384 bytes | 65536 bytes |
| Outbound slots | 32 | 256 |
| Inbound slots | 32 | 256 |
| Bytes in each direction | 524288 | 16777216 |
| Participating hosts | 32 | 32 |
| Duplicate identities | 1024 | 16384 |
| Duplicate window | 60000 ms | 600000 ms |

- CL-FEDERATION-REQ-106: Before a caller submits a publication payload to a bridge mailbox, the local admission gate shall reserve one fixed slot.
- CL-FEDERATION-REQ-107: The local admission gate shall limit its slot count to the lesser of the configured count and the byte budget divided by the maximum envelope size.
- CL-FEDERATION-REQ-108: If a caller exits or times out, then the local admission gate shall retain its unresolved permit until completion or closure of that bridge generation.
- CL-FEDERATION-REQ-109: If the duplicate cache is full, then the receiver shall reject a new export rather than evict an unexpired identity.

The gate uses atomic ETS insertion in the caller. It sends no admission message
to the bridge. Each slot reserves the maximum envelope size, so small payloads
can exhaust slots before their actual bytes exhaust the budget. This deliberate
tradeoff avoids a separate byte-counter repair problem after caller death. A
permit is released only after its queued work ends. A caller that dies before
submission can leave a charged slot until that bridge generation closes. Automatic
timeout reclamation could admit more messages while old messages remain queued.
An owner exit closes the old table; old handles cannot admit new work.

Byte budgets count the complete external-term envelope, not VM headers, caller
memory, or Agent mailboxes. Duplicate-cache expiry uses monotonic milliseconds.
A duplicate does not extend its original deadline. The candidate cache update is
retained only after local Bus append succeeds. Cache loss on bridge restart or
expiry permits a later duplicate. No exactly-once claim is made.

Current evidence is in [declaration tests](../../../test/jido_cluster/federation/declarations_test.exs),
[envelope tests](../../../test/jido_cluster/federation/envelope_test.exs),
[gate tests](../../../test/jido_cluster/federation/gate_test.exs), and
[cache tests](../../../test/jido_cluster/federation/dedup_test.exs). The gate case
uses 128 concurrent callers and four slots. These are primitive tests, not proof
of a complete transport or receiver mailbox bound. Planner admission currently
returns `:federation_not_implemented` for a topology with channels. Remove that
explicit rejection only with required attachment and runtime tests.

## Connected transport implementation

`Federation.Transport` defines the internal `transmit/2` boundary. Its connected
implementation establishes one sender process and one receiver-issued credit per
connection. The receiver binds the credit to the exact sender PID. Connection
admission checks the configured host list and the inbound slot/byte budget. Each
credit reserves the maximum envelope size for its full lifetime, including idle
periods. This is conservative capacity use; it is not a shared unbounded queue.

- CL-FEDERATION-REQ-110: Before submitting a payload to its mailbox, the connected sender shall acquire its one local slot.
- CL-FEDERATION-REQ-111: While an acknowledgement is unknown, the connected sender shall retain that slot and reject another payload.
- CL-FEDERATION-REQ-112: The connected receiver shall append valid imports only to its local Bus without exporting them.
- CL-FEDERATION-REQ-113: If a sender disconnects, then the receiver shall retain its credit until confirmed sender exit or receiver generation closure.

Data transmission uses native BEAM send with `:nosuspend` and `:noconnect`.
It does not start a connection, create a remote RPC task, or enqueue a retry.
A sender transmits at most one envelope before acknowledgement. Acknowledgement
means local Bus append, duplicate suppression, or a known rejection; it never
means application consumption. On timeout, the caller gets uncertainty while the
sender keeps its slot. A late matching acknowledgement releases it. A confirmed
receiver exit closes the sender generation. `:noconnection` does not do so.

Receiver credits also remain charged after a sender disappears in a partition.
Reconnection alone does not prove that old messages or actors are gone. Current
source keeps such a credit uncertain. S5 still needs explicit lifecycle
reconciliation. A receiver generation may be closed after its owned resources
are checked; this transport does not independently authorize deployment cleanup.

The payload bound covers admitted Signal envelopes in sender/receiver mailboxes
and distribution submission. Fixed protocol tags, PIDs, references, VM headers,
and control messages are additional overhead. Their protocol count is bounded by
connections and outstanding credits; the envelope byte budget is not a claim
about total VM memory. Connection setup and status are control operations. Normal
publication must reuse these established connections; it must not create a new
connection per publication. Agent mailboxes remain outside this transport bound.

The receiver validates scope, allowed types, hop count, and envelope size before
local append. It commits the duplicate-cache candidate only after append succeeds.
Cache saturation rejects new exports while preserving unexpired identities. Bus
append rejection leaves the original export retryable. Receiver and sender status
report counts and uncertainty without Agent payloads; crash status is redacted.

[Local transport tests](../../../test/jido_cluster/federation/connected_test.exs)
use a real Signal Bus with a controlled Store append boundary. They prove original
Signal preservation, duplicate suppression, 128 concurrent rejected submissions
behind one blocked credit, timeout retention, late acknowledgement, append
rejection, cache saturation, invalid configuration, and checked process closure.
[Peer transport tests](../../../test/jido_cluster/distributed/federation_transport_test.exs)
use actual connected BEAM transmission. A three-host case proves delivery and
original atom-keyed/binary data, then holds append and rejects excess work. The
spare host cannot acquire a credit beyond capacity. A two-host partition case
retains an unacknowledged credit after sender exit while disconnected and rejects
a new connection after reconnection. Checked peer cleanup closes the fixture.

No mirror supervisor, local publication receipt, required Agent attachment, or
S4 living example is supplied by this transport increment. The Planner rejection
remains until those contracts have runtime proof. The controlled Bus Store is a
test-only failure fixture; it does not replace a production Signal backend.

## Primitive verification

`mise exec -- mix quality` passes format, warnings-as-errors compilation, strict
Credo, and Doctor. Doctor reports 94 passing modules and 100% documentation and
spec coverage. `mise exec -- mix test.all` passes 211 tests with seed 0 in
74.2 seconds. This includes 18 S4 primitive tests and the existing peer and living
example suites. The real Bedrock path still passes. This was the primitive increment; transport
evidence is recorded above. S4 living examples remain pending. Review remains
Pending approval.

## Transport verification

`mise exec -- mix quality` passes. Doctor reports 97 passing modules and 100%
documentation and spec coverage. The isolated `mise exec -- mix test.all` run
passes 221 tests with seed 0 in 76.0 seconds. This includes eight local transport
tests and two real peer transport tests. The real Bedrock and existing living
examples remain in the same passing run. S4 publication, binding, and example
requirements are still incomplete. Review remains Pending approval.

## Local publication implementation

`Federation.Bridge` now connects explicit local publication to the transport
boundary. It receives an existing local Bus, channel scope/types/limits, and
already-established interested-host handles. `Federation.Channel` shares static
scope/type/limit validation between bridges and receivers. Neither module starts
Agents or changes deployment readiness. Planner admission remains closed for
channel deployments until required attachment is implemented.

- CL-FEDERATION-REQ-114: Before local Bus append, the bridge publication API shall reserve an outbound slot without sending its payload to the bridge mailbox.
- CL-FEDERATION-REQ-115: If local append is rejected, then the bridge shall release the slot and submit no export.
- CL-FEDERATION-REQ-116: When local append and bounded export submission succeed, the bridge shall return a receipt with the original Signal ID, distinct export ID, channel scope, and selected destination hosts.
- CL-FEDERATION-REQ-117: While an export task can still run, the bridge shall retain its admission slot until confirmed task exit.
- CL-FEDERATION-REQ-118: If a later transport result is rejected or unknown, then the bridge shall report that observation without undoing local acceptance.
- CL-FEDERATION-REQ-119: While any publication slot remains charged, the bridge shall reject a destination-set change.

The receipt fields are `local: :accepted` and `outbound: :submitted`. They mean
local Bus append and bounded task submission. Remote append, delivery order,
Agent execution, persistence, and business replay are separate concerns. Each
explicit publication creates a fresh export identity, even if its Signal ID was
used before. A timeout returns publication uncertainty; it does not cancel the
append or reclaim its slot. A retry is another export and is not automatically
deduplicated against the timed-out publication.

Each admitted publication has at most one export task. It visits interested hosts
in deterministic order. At most `max_hosts - 1` distinct remote hosts are allowed;
self-export and duplicate hosts are rejected. A failure at one destination does
not prevent submission to later destinations. Tasks run under a bridge-owned
Task.Supervisor. Slots release after the task's monitor confirms exit, not merely
when its result message arrives. Bridge shutdown closes admission and stops its
owned tasks. The separately supplied Bus and transport connections have their own
owners; mirror supervision still needs to bind those lifetimes.

An unknown task-start result retains its slot until generation closure. Status
reports `submission_uncertain` and degradation. Successful task submission can
complete or fail before the caller observes the receipt; neither result changes
what the receipt establishes. Transport exceptions become uncertainty. Known
capacity, closed-gate, disconnected-send, and receiver-cache rejections are counted
separately. The bridge keeps bounded per-host failure observations and counters,
not an unbounded history of publication payloads.

Only the explicit API exports Signals. The bridge does not subscribe to its Bus.
Ordinary local Bus publications and receiver imports therefore do not produce
new exports. `health` is the last observed submission health; it is not a current
Agent, binding, or idle connection observation. Mirror/facade integration still
needs those independent observations. High-frequency export telemetry includes
namespace, topology ID, channel, generation, export ID, host, and phase, without
Signal payloads. It does not write the deployment journal.

[Bridge tests](../../../test/jido_cluster/federation/bridge_test.exs) use the
bounded [recording transport](../../../test/support/federation/recording_transport.ex)
through the real transport behaviour. They hold submissions, fill both slots,
then reject 128 concurrent callers before local append. They also cover append
rejection, publication timeout, transport exception, continued fanout after one
host fails, target-update exclusion, and checked task exit on shutdown.

[The publication peer test](../../../test/jido_cluster/distributed/federation_publication_test.exs)
uses actual BEAM connections in both directions between two peers. A third peer
has no interest, and another deployment on the receiving peer uses the same
channel key. Explicit publications reach only their configured destinations.
Original Signal data survives, imports do not loop through the reverse bridge,
and ordinary local Bus publication is not exported. Completion is observed through
transport/task results and public Bus records, without sleeps as negative proof.
The fixture manually owns its components; it does not yet prove production mirror
supervision, required Agent subscriptions, or the S4 living examples.

## Publication verification

`mise exec -- mix quality` passes. Doctor reports 99 passing modules and 100%
documentation and spec coverage. The isolated `mise exec -- mix test.all` run
passes 232 tests with seed 0 in 76.7 seconds. This includes ten local bridge tests
and the real three-peer publication test. Existing Bedrock, recovery, transport,
and living-example tests remain in the same passing run. Mirror supervision,
required Agent bindings, facade integration, and S4 living examples remain
incomplete. Review remains Pending approval.

## Mirror ownership implementation

`Federation.Mirror` now owns one local Bus, receiver, bridge, and export task
supervisor for an exact deployment activation and channel. The application owns
the mirror process. A requester can exit or discard its start reply without
removing that ownership. The local Registry key contains the core name,
activation ID, and channel key. Configuration includes the exact local core PID.
Concurrent `ensure/1` calls with identical configuration return the same mirror.
A different configuration is rejected.

- CL-FEDERATION-REQ-120: Before a mirror creates child resources, Activation shall record the exact mirror PID under its host and channel key.
- CL-FEDERATION-REQ-121: When deployment cleanup starts, Activation shall close admission for new resource claims before the owner requests resource cleanup.
- CL-FEDERATION-REQ-122: While any claimed resource lacks an exact cleanup receipt, Activation shall reject deployment settlement.
- CL-FEDERATION-REQ-123: When mirror cleanup confirms local component exit and orderly export-supervisor exit, the mirror shall record resource settlement from its own PID.
- CL-FEDERATION-REQ-124: If a mirror or its export supervisor exits without confirmed cleanup, then Activation shall retain resource uncertainty.
- CL-FEDERATION-REQ-125: While the deployment owner is disconnected, the mirror shall retain its resources and report uncertain control.
- CL-FEDERATION-REQ-126: When the exact local core or a connected deployment owner exits, the mirror shall close its local generation.

Activation retains at most 256 host/channel records per attempt, matching eight
channels on up to 32 hosts. Repeating the same deployment claim preserves these
records. They contain runtime PIDs and cleanup evidence in control-VM memory;
they are not written into the portable journal. Only the process that claimed a
resource can settle it. A dead process or missing Registry entry is not a receipt.
The current implementation does not replace a mirror within the same activation.
That generation replacement contract remains lifecycle work.

The Scheduler owner closes activation admission, reads the retained resource
keys, and requests cleanup on each recorded host before it stops core ownership.
Each host request has a five-second deadline. An unavailable host or unknown
reply retains uncertainty. Once admission is closed, an unclaimed channel can
be confirmed absent: a delayed start can no longer claim it. A claimed channel
needs its exact receipt even when its process is absent. This removes reliance
on a requester task's local list of successful start replies.

Each mirror uses a local Memory Store Bus with a 1024-record log limit. The
existing inbound and outbound limits still apply. Bus retention and Agent
mailboxes are separate from the federation payload budgets. Components do not
restart inside a generation. Core or owner exit triggers cleanup; a disconnected
owner only changes the control observation. Reconnection alone does not prove
cleanup or replace a generation.

The mirror checks component monitor messages during shutdown. It also observes
the export task supervisor through `Bridge.work_owner/1`. Orderly supervisor exit
confirms its task cleanup; abrupt supervisor loss leaves the resource record
uncertain. Bridge shutdown waits for its task supervisor to finish. Cleanup
timeouts do not erase the retained resource record.

[Activation tests](../../../test/jido_cluster/activation_test.exs) cover admission
closure, retained child ownership, rejection of a forged receipt, and delayed
resource requests. [Local mirror tests](../../../test/jido_cluster/federation/mirror_test.exs)
cover 64 concurrent requests, a discarded reply, closure racing with start,
configuration mismatch, core and owner exit, component failure, abrupt mirror
loss, and abrupt export-supervisor loss. They check component exit and closed
publication gates through public observations.

[Peer mirror tests](../../../test/jido_cluster/distributed/federation_mirror_test.exs)
attach mirrors to a real deployment owner on two nodes. Normal deployment stop
finds and closes both mirrors through activation records. A second test creates
a live two-way partition, proves that the remote mirror and claims remain, then
reconnects and performs explicit journal reconciliation before cleanup completes.
The journal in these tests uses the real Mnesia adapter. The tests attach mirrors
directly; they do not yet prove channel declarations produce ready subscriptions.

Required Agent bindings, interest connections, publication facade integration,
and S4 living examples remain pending. Planner admission remains closed for
channel deployments. This increment does not complete S4 or start S5.

## Mirror verification

`mise exec -- mix quality` passes. Doctor reports 100 passing modules and 100%
documentation and spec coverage. The isolated `mise exec -- mix test.all` run
passes 247 tests with seed 0 in 78.8 seconds. The increment adds two activation
resource tests, eleven local mirror tests, and two real peer mirror tests. The
existing real Bedrock, recovery, publication, and living-example tests remain
in the same passing run. Review remains Pending approval.

## Local binding and owned connection implementation

`Federation.Binding` now owns the local subscriptions for one channel and exact
Agent incarnation. Its stable logical ID includes the channel scope and core
Ref. Its runtime subscription IDs also include a fresh generation. The process
starts without attaching or creating an Agent. `attach/1` checks the local core
lifetime, resolves the Ref to the accepted PID, waits for core readiness, and
checks the same target after subscription setup.

- CL-FEDERATION-REQ-127: Before binding attachment, Binding shall confirm that its accepted local PID is the current ready target of the declared Ref.
- CL-FEDERATION-REQ-128: When the same binding is attached again, Binding shall reuse its existing subscriptions.
- CL-FEDERATION-REQ-129: If attachment fails after some subscriptions were created, then Binding shall remove only the subscriptions created by that attempt.
- CL-FEDERATION-REQ-130: When a caller's attachment wait expires, Binding shall retain the in-progress attempt and report uncertainty to that caller.
- CL-FEDERATION-REQ-131: When the accepted Agent incarnation exits, Binding shall report loss without attaching to a replacement PID.
- CL-FEDERATION-REQ-132: While a required declared binding is not ready, Mirror shall report pending or degraded binding readiness.
- CL-FEDERATION-REQ-133: When Mirror receives the same fixed destination set again, Mirror shall reuse each prior connection attempt.
- CL-FEDERATION-REQ-134: If connection setup fails, then Connections shall retain that interested host as a closed publication target.
- CL-FEDERATION-REQ-135: When an owned sender exits, Mirror shall report degraded transport health while retaining its local Bus and bindings.

Each allowed exact type has an ephemeral Bus subscription. The local Bus sends
the original Signal directly to the Agent's normal handler. Binding adds no event
mailbox or forwarding process. Its status contains the logical ID, Ref, fixed
target, required flag, phase, readiness, reason, and bounded subscription records.
Readiness observes the owned subscription receipts, core lifetime, and current
Agent readiness. It is not a consumption receipt or durable cursor. The mirror
owns these subscriptions; direct external changes to its Bus routes are outside
this attachment contract.

An attachment timeout does not cancel the work. A later result can complete the
same attempt, and another attach call reuses it. A partial failure rolls back
known owned IDs. A conflicting pre-existing ID is not deleted. Unknown detach
retains uncertainty. Confirmed Bus exit proves that its ephemeral routes are gone.
Successful detach closes the binding and does not stop the Agent. Optional missing
bindings remain visible but do not block the required-binding readiness result.

Mirror validates at most 64 distinct Ref declarations. It starts and monitors
binding processes under its owned supervisor. An attachment target is fixed for
that generation. Agent exit changes binding readiness but leaves the mirror alive.
Unexpected binding process exit closes the generation, so a lost binding owner
cannot leave its subscriptions active on a surviving mirror Bus.

`Mirror.connect/2` accepts a fixed list of exact receiver descriptors. Destinations
must be unique, known, remote hosts with the same channel scope and allowed types.
There are at most `max_hosts - 1` destinations. `Federation.Connections` starts one
supervised connected sender per destination and supplies bridge handles. It does
not add another payload mailbox. Setup and publication reuse the existing sender
gate and receiver credit protocol.

A refused or unknown setup attempt stays in the manifest with a closed handle.
The publication receipt still names the host. Local append and task submission can
succeed, then the bridge records a known rejection because that handle submits no
payload. Connection status retains the setup reason. Repeated setup does not retry
or consume more credits, even if capacity later becomes available. Static interest
cannot change within this generation; movement and replacement remain S5 work.

Live connection health is separate from the bridge's historical submission
counters and required binding readiness. Before a destination set is supplied,
Mirror reports pending federation health. A configured empty set is healthy.
Sender loss degrades health but does not close the local Bus or bindings. All known
sender processes remain in mirror cleanup evidence. Their exit does not authorize
Agent replacement or change capacity claims.

[Binding tests](../../../test/jido_cluster/federation/binding_test.exs) use real
AgentServers and the local Bus. They prove exact type filtering, original event
fields, repeat attachment, selective detach, wrong-target rejection, replacement
refusal, Bus loss, partial rollback, and a late result after caller timeout. The
partial-failure test uses public subscription IDs to create a conflict while the
Agent stays alive. The timeout test uses a public telemetry barrier.

[Mirror tests](../../../test/jido_cluster/federation/mirror_test.exs) prove required
and optional readiness, owned attachment, and degradation after Agent exit.
[Peer binding tests](../../../test/jido_cluster/distributed/federation_binding_test.exs)
use real deployment owners, local mirrors, connected senders, and Agent state.
They prove remote import through the normal Agent path, rejection of a remote PID
for a local Bus, connection reuse, transport loss without binding loss, setup
refusal, retained interested targets, and checked deployment cleanup.

These tests configure mirrors explicitly after an Agent deployment. The next
increment below adds declarative deployment and facade tests. Living examples
remain a separate S4 completion requirement.

## Binding and connection verification

`mise exec -- mix quality` passes format, warnings-as-errors compilation, strict
Credo, and Doctor. Doctor reports 102 passing modules and 100% documentation and
spec coverage. The isolated `mise exec -- mix test.all` run passes 258 tests with
seed 0 in 80.5 seconds. This increment adds eight local binding tests, one mirror
readiness test, and two real peer binding/connection tests. The full run includes
the existing Bedrock, recovery, ownership, publication, and living-example tests.
At this verification point, declarative integration, facade APIs, and living
examples were still incomplete. The next increment is recorded below. Review
remains Pending approval.


## Declarative deployment and facade implementation

`Federation.Runtime` resolves each declared binding to the accepted root Ref and
host. Its pure plan counts the control publisher and all subscribing hosts against
`max_hosts`. Uninterested inventory hosts get no channel mirror. Instance config
accepts `federation: [...]` limit overrides; unknown or unbounded values fail
validation. These limits apply to each host-local channel mirror.

The deployment Owner runs setup after Core confirms Agent readiness. It creates
mirrors under exact activation resource claims, attaches each declared local Ref,
and checks required attachment receipts. Initial completion follows these receipts.
Optional attachment results remain visible without blocking required readiness.
Mirror setup failure leaves the operation uncertain and retains cleanup ownership.

- CL-FEDERATION-REQ-136: Before accepting a channel deployment, the instance service shall validate the channel participant count against its configured host limit.
- CL-FEDERATION-REQ-137: Before initial deployment completion, Runtime shall confirm each required local binding receipt after Core Agent readiness.
- CL-FEDERATION-REQ-138: While a mirror's fixed destination manifest is not configured, Mirror shall reject a publisher handle request.
- CL-FEDERATION-REQ-139: Before sending a publication payload to a federation process, the publication caller shall reserve its bridge gate.
- CL-FEDERATION-REQ-140: When current binding or transport health changes, the status facade shall preserve historical operation results.
- CL-FEDERATION-REQ-141: While channel movement has no implemented lifecycle protocol, Planner shall reject a channel placement change before movement effects.

Each source mirror connects once to every other interested host. Connection
failure does not revoke a confirmed local binding receipt. Known failed sender
setup remains a closed target. If a complete receiver manifest cannot be obtained,
the mirror remains unconfigured and cannot publish. A cached publisher handle
avoids a Bridge call before admission, so a held local append cannot prevent
concurrent callers from rejecting a full gate.

The public APIs are:

```elixir
Jido.Cluster.publish(instance, topology_id, :events, signal)
Jido.Cluster.federation_status(instance, topology_id)
Jido.Cluster.status(instance, topology_id)
```

The facade currently publishes on the instance's control node. It obtains
control context using IDs only, then reserves the local bridge gate. The Signal
does not pass through the instance service mailbox or an RPC payload path. A
remote caller using a service PID is rejected with `:publisher_not_local`.
Publication requires initial completion, running intent, ready journal authority,
and active ownership. Its receipt still means local append and bounded outbound
submission, not remote execution.

Federation status reads current mirror, binding, sender, and capacity observations
outside the journal service. Each host read and the total host-read pass have
bounds. A busy component can report unavailable metrics. No status read writes
the journal. Deployment status reports Agent readiness separately from binding
readiness, transport health, and operation phase. Stopped completion closes
publication and reports stopped federation readiness.

Static channel admission is now open. Direct legacy Scheduler startup rejects
channels without managed deployment ownership. A changed channel placement
returns `:federation_movement_not_implemented`, including the reserved operation
path. S5 still owns generation replacement, movement, and recovery policy.

[Local deployment tests](../../../test/jido_cluster/federation/deployment_test.exs)
prove declarative attachment, original Signal handling, type/channel rejection,
checked stop cleanup, validated limits, and legacy ownership rejection. Public
telemetry barriers prove that required attachment delays completion, Bus loss
during attachment prevents completion, and sixteen concurrent callers reject a
full publication gate while the first append is held. Only the admitted Signal
appears in the Bus log after the barrier is released.

[Three-host deployment test](../../../test/jido_cluster/distributed/federation_deployment_test.exs)
proves declared remote delivery, exclusion of an uninterested host, preservation
of the original Signal, and no import re-export. Sender loss changes federation
health while Agent/binding readiness and the completed operation remain unchanged.
The test checks exact mirror/component exit and released claims on stop.
The required living examples remain pending, so S4 is not complete.


A full regression run found that legacy Core instances can omit a namespace.
Runtime now skips federation identity checks when a topology has no channels.
The existing Scheduler shutdown test covers this path without changing its
configuration. The focused Scheduler and declarative deployment run passes all
11 tests with seed 0 after the correction.


## Declarative integration verification

`mise exec -- mix quality` passes format, warnings-as-errors compilation, strict
Credo, and Doctor. Doctor reports 103 passing modules with complete documentation
and spec coverage. After the legacy namespace correction, the isolated
`mise exec -- mix test.all` run passes 264 tests with seed 0 in 83.3 seconds.
The six added tests cover declarative setup and the public publication/status
paths. The full run retains the real Bedrock tests and all existing examples.
The updated placement guide (retired path: `../../../guides/placement.md#static-federated-channels`)
describes the public API, limits, receipts, and static-host restriction. S4 living
examples, S5–S7, both cumulative examples, and Docker proof remain pending.
Review remains Pending approval.


## Living examples and S4 acceptance audit

The three planned examples now use actual topology declarations and required
bindings. Each primary source defines its Recorder first, then its topology and
Cluster instance. The Recorders use normal typed Agent routes, generated command
Signals, and original Signal fields. No application Action contains a test hook.
The shared test fixture owns host setup and cleanup. Every example uses only the
`:example` tag through ClusterCase.

| Scenario | Source and README | Executable proof |
| --- | --- | --- |
| 07_01 interested hosts | [Source](../../../examples/07_federation/07_01_interested_hosts/events.ex), [README](../../../examples/07_federation/07_01_interested_hosts/README.md) | [Test](../../../test/examples/07_federation/07_01_interested_hosts/interested_hosts_test.exs): A-to-B delivery, C excluded, distinct deployment and namespace isolation, original Agent event fields, checked cleanup |
| 07_02 envelope and loops | [Source](../../../examples/07_federation/07_02_envelope_and_loops/events.ex), [README](../../../examples/07_federation/07_02_envelope_and_loops/README.md) | [Test](../../../test/examples/07_federation/07_02_envelope_and_loops/envelope_and_loops_test.exs): actual bidirectional connections, repeated export suppression, no import re-export, exact Bus records and Agent state, checked cleanup |
| 07_03 bounded publication | [Source](../../../examples/07_federation/07_03_bounded_publication/events.ex), [README](../../../examples/07_federation/07_03_bounded_publication/README.md) | [Test](../../../test/examples/07_federation/07_03_bounded_publication/bounded_publication_test.exs): two held slots, rejection before append, released capacity, reported later failure without rollback, checked cleanup |

The first two examples use connected BEAM transport. The third uses the existing
recording transport fixture to control submission results; its acknowledgements
do not prove remote delivery. All use explicit memory journal mode and memory
Bus logs. Real Bedrock durability remains covered by S3; these examples do not
claim durable event delivery. The focused command is
`mise exec -- mix test test/examples/07_federation --only example --seed 0`.
It passes three tests. The catalog lists the exact source, test, and support files.

The audit checked each S4 implementation step, named example, and numbered
requirement against source and executable observations. It added explicit tests
at the declaration count boundaries, for publisher rejection before successful
configuration, for participant rejection before activation, for drain rejection
before movement, and for lost current binding readiness with unchanged history.
The full-goal audit still needs S5–S7 and both cumulative examples.

| Requirement | Inspected evidence |
| --- | --- |
| CL-FEDERATION-REQ-101 | [Declaration tests](../../../test/jido_cluster/federation/declarations_test.exs): accept 8 channels, 32 exact types, 64 bindings; reject the first excess in each dimension |
| CL-FEDERATION-REQ-102–104 | Same declaration tests: exact namespace/topology scope and Refs, invalid/duplicate metadata, pure lowering and journal definition round trip; 07_01 proves runtime isolation |
| CL-FEDERATION-REQ-105 | [Envelope tests](../../../test/jido_cluster/federation/envelope_test.exs): preserve all Signal fields and reject invalid hop/header/scope; 07_02 proves connected delivery |
| CL-FEDERATION-REQ-106–108 | [Gate tests](../../../test/jido_cluster/federation/gate_test.exs): concurrent slot admission, byte budget, caller exit retention, generation closure; [Bridge tests](../../../test/jido_cluster/federation/bridge_test.exs) retain admission after timeout |
| CL-FEDERATION-REQ-109 | [Cache tests](../../../test/jido_cluster/federation/dedup_test.exs) and [connected tests](../../../test/jido_cluster/federation/connected_test.exs): protect unexpired identities at saturation |
| CL-FEDERATION-REQ-110–113 | Connected tests and [peer transport tests](../../../test/jido_cluster/distributed/federation_transport_test.exs): one outstanding payload, held credit, late acknowledgement, local import, disconnect retention |
| CL-FEDERATION-REQ-114–119 | Bridge tests: pre-append gate, append rejection, receipt fields, owned task exit, failure observation, immutable busy target set; 07_03 proves the public publication path |
| CL-FEDERATION-REQ-120–124 | [Activation tests](../../../test/jido_cluster/activation_test.exs) and [Mirror tests](../../../test/jido_cluster/federation/mirror_test.exs): exact resource claims before children, closed admission, retained unknown cleanup, exact settlement, abrupt-loss uncertainty |
| CL-FEDERATION-REQ-125–126 | Mirror tests and [peer Mirror tests](../../../test/jido_cluster/distributed/federation_mirror_test.exs): live partition retention, uncertain control, exact Core/owner exit and cleanup |
| CL-FEDERATION-REQ-127–131 | [Binding tests](../../../test/jido_cluster/federation/binding_test.exs): current local Ref/PID checks, repeat attachment, partial rollback, late result, refusal of replacement PID |
| CL-FEDERATION-REQ-132 | Mirror required/optional tests and [deployment tests](../../../test/jido_cluster/federation/deployment_test.exs): initial attachment barrier and current lost readiness |
| CL-FEDERATION-REQ-133–135 | [Peer binding tests](../../../test/jido_cluster/distributed/federation_binding_test.exs): connection reuse, retained failed target, sender loss independent of ready binding |
| CL-FEDERATION-REQ-136 | [Peer deployment tests](../../../test/jido_cluster/distributed/federation_deployment_test.exs): plan/deploy reject participant excess before claims or activation |
| CL-FEDERATION-REQ-137 | Deployment tests: Core ready while a required attachment receipt is held; loss prevents initial completion |
| CL-FEDERATION-REQ-138 | Mirror test: pending publisher, unsuccessful busy setup, successful setup, then closed-activation rejection |
| CL-FEDERATION-REQ-139 | Deployment test: sixteen concurrent full-gate rejections while local append is held; only the admitted Signal appears in the log |
| CL-FEDERATION-REQ-140 | Deployment tests preserve completed history after required binding loss; peer deployment test preserves it after sender loss |
| CL-FEDERATION-REQ-141 | The original S4 peer test rejected drain before effects. S5 now supplies the managed lifecycle protocol and replaces that test with movement proof. Direct legacy Planner calls retain the restriction. See the [S5 record](../05_federation-lifecycle/plan.md#journaled-subscriber-movement). |

The shared CL-READY-REQ-001–003 and CL-QUEUE-REQ-001–003 requirements are covered by
the deployment, peer sender-loss, concurrent publication, envelope, and receiver
capacity tests above. The queue model states the admitted slots, payload bytes,
receiver credits, and native-send behavior. Agent mailboxes, ordinary local Bus
publishers, caller memory, and VM object overhead remain outside these bounds.
No extra transport dependency was added. Generation replacement and movement
remain S5 work. Review status remains Pending approval.


## Final S4 verification

`mise exec -- mix quality` passes formatting, warnings-as-errors compilation,
strict Credo, and Doctor. Doctor reports 115 passing modules with 100% documentation
and spec coverage. The isolated `mise exec -- mix test.all` run passes 272 tests
with seed 0 in 89.1 seconds. It includes all three new living examples and the
five additional contract checks from the audit. Real Bedrock and the earlier
recovery/examples remain in the same run. Cleanup assertions pass.

`MIX_ENV=prod mise exec -- mix compile --warnings-as-errors` also passes. The
production path compiles only `lib`; examples and test support are excluded. No
optional transport dependency is required or added. The cold dependency build
emits existing warnings from `uniq` and `sweet_xml`; Cluster compilation passes.
The example catalog has matching source/test folders, only the `:example` tag,
valid local links, and no private-state or timed-absence checks. S4's static-host
acceptance scope is complete. This does not complete S5–S7, either cumulative
example, or Docker verification. Review remains Pending approval.


`mise exec -- mix docs` passes with the new section and all three example pages.
Catalog pairs, tags, source files, and local links pass inspection. Final
whitespace checks pass. No commit, push, or sibling source change was made.
