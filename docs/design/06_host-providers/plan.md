# S6 — Owned hosts and the first provider

Status: implementation and acceptance complete; review pending approval. Written on
2026-09-15 and verified on 2026-09-16. The provider contract, controlled service,
real Docker backend, five provider examples, and cumulative example have passing
evidence below. See the [final S6 audit](#real-docker-acceptance-and-s6-audit) and
[scope and dependencies](README.md).

## Outcome

Acquire compatible BEAM capacity and release it after Agent and federation
cleanup. Use Docker as the proposed first local proof; add hosted backends later.

## Implementation steps

1. Review LitterBox's current creation, inspection, and release paths. Record
   whether reuse helps; do not add its full API or dependency without that review.
2. Define provider acquire, inspect, and release contracts. Inspection accepts the
   stable resource-step ID even when an acquisition response was lost.
3. Add a fake provider with controlled timeouts and failures; run lifecycle tests
   before implementing a real backend.
4. Add host sessions and journal records for ownership, provider ID, incarnation,
   desired release, compatibility, and claims. Enforce acquisition limits.
5. Implement a Docker adapter using a prepared trusted release. Tag resources with
   stable operation identity and inspect before retrying an uncertain creation.
6. Verify connectivity, namespace, release compatibility, required local services,
   and persistence before activation. Start required federation host resources.
7. Release owned capacity only after Agent cleanup, binding cleanup, and all shared
   claims settle. Add the acquired-host topology example.

## Contracts and lifecycle

Borrowed resources are never destroyed. Owned resources require matching provider
identity and incarnation for release. Keep credentials in runtime configuration,
not topology metadata or journal records. Resource readiness, connected runtime
readiness, and topology readiness are distinct states.

The provider owns only the specified resource unit. Future Kubernetes adapters
must distinguish pods/workloads from node infrastructure. Start with dedicated
acquired hosts; any shared use must preserve S2 claim accounting. A tool-only
sandbox is outside this host contract.

## Failure handling

- Acquire timeout: inspect the original step; never retry with a fresh identity.
- Incompatible runtime: do not activate; clean up owned resources or report uncertainty.
- Coordinator loss: recover resource records before new acquisition.
- Release timeout: retain the host record and inspect; do not report released.
- Remaining claims: keep the host regardless of one deployment's stop request.

## Tests and completion

Run provider contract tests against the fake and Docker backends. Cover lost
acquire response, duplicate request, partial boot, wrong namespace, coordinator
restart, and stale release. Deploy a topology with federation, commit work, stop,
and verify actual resource deletion. Verify borrowed resources remain running.

Done when resource ownership and final cleanup are externally observed, and the
base package still works without the optional provider integration.

Write the unit contracts first, then local peer tests, then the tagged living
example. Run relevant package format, compile, quality, and test checks. Record
actual results and evidence links here before marking this slice complete.

## Example-based acceptance plan

Status: all five controlled examples and their real Docker runs pass. Follow the
[shared example test method](../00_architecture/example-testing.md).

Proposed group: `examples/09_host_providers/`, mirrored under
`test/examples/09_host_providers/`. These numbers extend the existing 01–03 groups;
confirm they remain free before implementation. Keep scenario IDs stable once added.

### Setup

Use a local control instance, an application-owned persistence service, and a
prepared Docker worker release. Keep provider resource IDs and request IDs unique
per test. First run the same lifecycle against a controlled fake provider.

### Scenarios

| Proposed example | Actions | Required observations |
| --- | --- | --- |
| `09_01_acquired_topology` | Acquire a host, deploy a core topology with a federated subscriber, commit work, stop, and inspect the provider. | Resource readiness precedes runtime checks and Agent readiness. Final release occurs only after Agent and binding cleanup. The actual container is gone. |
| `09_02_lost_acquire_reply` | Create the resource but withhold the acquire reply; kill/restart the coordinator and inspect by the original step ID. | Only one resource exists for that step. Restart adopts recorded evidence or reports uncertainty; it does not create another host. |
| `09_03_borrowed_and_incompatible` | Run once with borrowed capacity and once with an acquired incompatible runtime. | Stop retains borrowed infrastructure. Incompatible capacity starts no Agent; owned cleanup either completes or stays explicitly uncertain. |
| `09_04_release_guard` | Hold a required binding cleanup, request release, then settle it. Replay a stale release for an old incarnation. | No early destruction occurs. Release proceeds after all claims settle. A stale incarnation cannot destroy a newer resource. |

### Evidence and failure control

The credential-free default suite uses the fake provider. The real Docker example
runs through a targeted test path with only `:example` as its tag; do not add an
OR-included provider tag. Detailed implementation must add an explicit runner or
configuration prerequisite for that path. Report an unavailable Docker runtime
as not run, never as passing provider evidence. CI needs a dedicated real-provider
job before this slice can be promoted.

Register cleanup as soon as a resource identity is known. After assertions, inspect
for leaked resources by test ownership label and remove only test-owned resources.
Cleanup must not turn a failed release assertion into a pass.

### Promotion record

For each scenario, add links to its source, README, and executable test. Record
the command, seed, backend, result, and cleanup result. Map every README guarantee
to an assertion. A fake-only result cannot prove an external backend contract.
Keep this slice incomplete until its required examples and lower-level contracts
pass; record unavailable cases explicitly.

## Cross-slice refinements

Reuse the S1 [host runtime contract](../00_architecture/lifecycle-contracts.md).
The provider supplies a prepared runtime that registers through the same protocol
as a static peer. Verify release/protocol compatibility, namespace, persistence
identity, required services, and new incarnation after restart.

Test control disconnect without declaring existing workers dead. Rejoin reconciles
activations and retained claims before new mutations. Preserve provider records
through incomplete service shutdown so later reconciliation can finish release.

Add the provider-backed cumulative scenario after the static S5 version passes.
Actual infrastructure inspection must establish final deletion. Keep borrowed
resources and unrelated allocations intact. Record the selected backend's connection
and prepared-release requirements before implementing its adapter.

## Final build refinements

Make reconciliation the primary external-resource cleanup mechanism. Inspect by
persisted resource-step identity after abrupt process death. Where supported, add
bounded discovery by ownership labels to find resources whose creation response
was lost; unknown or conflicting candidates remain uncertain until ownership and
cleanup conditions are established.

Add `09_05_abrupt_death_cleanup`: kill the owner without termination callbacks,
restart, reconcile, and inspect actual provider resources. Include a live resource,
a borrowed resource, and an old-incarnation candidate as preservation controls.
Model cleanup decisions as a pure function and test generated combinations.
Hyper remains optional prior art, not a selected backend or dependency.

## Decisions and limits

Docker is the implemented first local backend. Sprites, Fly Machines,
and Kubernetes follow the same suite after their resource/network contracts are
reviewed. No image builder or general terminal/file API is included.


## Initial provider contract and source review

Implemented the first contract increment on 2026-09-16, after the S5 checkpoint.
This is not a completed host-provider service or a Docker implementation.

### LitterBox review

Reviewed the clean local `main` checkout at commit
`2b9ac96da48e0c2eb46c7558a04d025abc09c4e8`. The source is in
`/Users/mhostetler/Source/Jido/proj_jido_workspace/litter_box`.

| Source at the reviewed commit | Finding for Cluster |
| --- | --- |
| [Architecture](https://github.com/zblanco/litter_box/blob/2b9ac96da48e0c2eb46c7558a04d025abc09c4e8/ARCHITECTURE.md) | LitterBox owns sandbox sessions, execution, files, services, and backend operations. It excludes durable workflow journals. Cluster needs only resource lifecycle mechanics here. |
| [Backend behaviour](https://github.com/zblanco/litter_box/blob/2b9ac96da48e0c2eb46c7558a04d025abc09c4e8/lib/litter_box/sandbox/backend.ex) | The behaviour has provision/destroy and optional session operations. It has no required inspection by a persisted acquisition step or release contract tied to Cluster claims. |
| [Docker session creation](https://github.com/zblanco/litter_box/blob/2b9ac96da48e0c2eb46c7558a04d025abc09c4e8/lib/litter_box/sandbox/backends/docker.ex#L979) | Creation uses an ephemeral `System.unique_integer` container name. It starts a generic shell loop and stores the returned name in session metadata. This does not establish recovery by a pre-recorded Cluster step. |
| [Docker session cleanup](https://github.com/zblanco/litter_box/blob/2b9ac96da48e0c2eb46c7558a04d025abc09c4e8/lib/litter_box/sandbox/backends/docker.ex#L1029) | Cleanup runs `docker rm -f`, ignores its result, and rescues errors as success. Cluster cannot use that result as a deletion receipt. |

Decision: keep LitterBox as prior art for explicit command arguments and prepared
runtime configuration. Do not add its full sandbox API or dependency. Implement
a narrow optional Docker adapter with stable step identity, exact inspection,
bounded calls, and independently checked deletion. Do not copy its cleanup result
semantics. This decision adds no image builder, terminal API, or workspace API.

### Implemented types and decision

[HostProvider](../../../lib/jido_cluster/host_provider.ex) defines acquire, inspect,
release, option validation, and optional bounded discovery. Runtime options stay
outside durable records. Acquire errors distinguish rejected from indeterminate
outcomes. Inspection distinguishes absent from unavailable. A successful release
call is only an accepted request; deletion still requires inspection.

[Step](../../../lib/jido_cluster/host_provider/step.ex) contains namespace, scope,
configured host ID, configured provider ID, and one stable attempt ID. Each string
is valid UTF-8 and 1–256 bytes. Its codec rejects missing or extra fields and never
creates atoms. [Resource](../../../lib/jido_cluster/host_provider/resource.ex)
adds exact provider resource ID, incarnation, and observed starting/running/stopped
state. Resource readiness does not establish connected runtime or Agent readiness.

[Release](../../../lib/jido_cluster/host_provider/release.ex) is a pure decision.
Borrowed resources and running intent are retained. Release requires confirmed
release intent, closed admission, no claims, and settled Agent and binding cleanup.
An unexpected incarnation is retained. A matching discovered resource with no
recorded handle returns an adoption decision; the service must journal that handle
before it can request release. An absent never-observed acquisition stays uncertain,
because absence alone cannot exclude a delayed creation. The decision makes no
provider call and grants no scope authority.

- CL-HOST-REQ-001: When an acquisition reply is indeterminate, the host session shall retain the original step identity for inspection.
- CL-HOST-REQ-002: If a provider cannot inspect a resource, then it shall report unavailability separately from authoritative absence.
- CL-HOST-REQ-003: When release addresses a different resource ID or incarnation, the provider shall reject the destructive request.
- CL-HOST-REQ-004: While a resource is borrowed or desired running, the release decision shall retain it.
- CL-HOST-REQ-005: While admission is open or cleanup evidence is incomplete, the release decision shall retain the resource.
- CL-HOST-REQ-006: When inspection discovers an unrecorded matching resource, the host session shall confirm its journal adoption before release.
- CL-HOST-REQ-007: If acquisition remains indeterminate and no resource was observed, then the host session shall retain uncertainty after an absent inspection.
- CL-HOST-REQ-008: When a provider accepts release, the host session shall inspect the original step before it records deletion.

Current evidence is limited to the
[controlled provider and decision tests](../../../test/jido_cluster/host_provider_test.exs).
Seven tests pass with seed 0. A generated Cartesian model covers 96 combinations
of ownership, intent, retained claims, Agent cleanup, binding cleanup, and admission
closure. It checks that only the fully settled owned release case permits an effect.
The fixture also tests lost replies, stable duplicate acquisition, stale release,
bounded discovery, portable records, and unavailable inspection. Its in-memory
closed-step set prevents recreation after release; Docker still needs an explicit
late-call decision and proof. No service, peer, or provider acceptance is inferred
from these tests.

### Integration contract

Host sessions use the existing scope authority and claim ledger. Record
acquire/release intent before provider calls. Record acquisition
identity, exact resource evidence, and unknown outcomes in the scope record.
Exclude hosts until direct runtime compatibility and HostRuntime reconciliation
succeed. Release exclusion must stay in force while prior claims, activation or
binding cleanup, and provider deletion are unresolved. Callbacks must address the
actual accepted task and step. Existing stopped deployment records must remain
available for resource cleanup after service restart.

Use configured provider and host IDs to resolve runtime options and node atoms.
Do not decode new node atoms or store credentials from provider records. Enforce
existing aggregate bounds before acceptance. Controlled service tests now cover this contract as listed below. The planned five provider examples and cumulative
variant remain required.

The local Docker prerequisite is currently unresolved: OrbStack reports Running,
but Docker info and direct socket `_ping` time out. The `orbstack` context uses
`unix:///Users/mhostetler/.orbstack/run/docker.sock`; the default socket is absent.
These probes create no resource and do not count as provider proof. Do not restart
shared infrastructure without checking its effect on other work.


Initial contract verification: `mise exec -- mix quality` passes with 145 modules
and complete documentation/specification coverage. `mise exec -- mix test.all`
passes 315 tests with seed 0 in 122.4 seconds. The unchanged live Bedrock fixtures
remain in that run: 64 bindings encode to 29,376 bytes, and the S3 aggregate encodes
to 53,094 bytes with 25 CAS writes in 49,288 microseconds. These measurements are
fixture observations. Provider service integration and real Docker are still pending.

Production compilation with warnings-as-errors and `mix docs` pass after the S6
contract increment. Local documentation links and `git diff --check` pass.
No commit, infrastructure restart, or sibling source change was made.

## Controlled service integration

Implemented on 2026-09-16. The scope journal now records provider inventory and
one [HostSession](../../../lib/jido_cluster/host_session.ex) per configured host.
Inventory stores the provider authority ID and owned/borrowed mode. Changing
either rejects the old record. Adapter options remain in local configuration.
An adapter's authority ID must identify the same external resource domain after
restart. Reusing that ID for a different endpoint violates the adapter contract.
No discovery result grants ownership.

The facade adds `acquire_host/3`, `release_host/3`, and `host_status/2`. Acquisition
requires a durable journal. It records an unused step, then records `attempted`
before the external call. A possibly executed call is inspected with the same
step on recovery. A resource observation is saved before runtime checks. Owned
hosts require an exact provider step in the booted HostRuntime, compatible Core
namespace, protocol, release, and persistence identity, and one dedicated Core
allocation. Multiple deployments share that allocation through normal claims.
Borrowed hosts can use a configured allocation and need no provider boot stamp.
Owned acquisition cannot target the control node.

Admission starts closed and closes again on journal restore. `enable_host/3`
does not bypass it. Recovery checks providers before replacement activation;
an unavailable provider keeps replacement blocked. Host recovery still works
after completed operation history expires. Pending journal intent is visible
through `host_status/2`, with closed admission and journal uncertainty.

Release records intent and closes admission before inspection. It retains a host
with scope claims. Before deletion, it checks all host claims, Core Agents, and
federation mirrors. A HostRuntime retirement step prevents later registration
for that Core lifetime. The service records a `deleting` cleanup receipt before
the provider effect. An absent inspection after this receipt can finish cleanup
without contacting the deleted runtime. A runtime that never passed activation
admission needs no Agent cleanup receipt. Borrowed release records `retained`
and makes no destructive provider call. A second release token cannot replace
an unresolved release; replay its token or reconcile the existing intent.

| Requirement | Required behavior | Current controlled evidence |
| --- | --- | --- |
| CL-HOST-REQ-009 | When owned acquisition can execute, the scope service shall confirm the attempted step in its journal first. | Unknown acceptance starts no provider call; recovery uses the recorded step. |
| CL-HOST-REQ-010 | When an owned runtime lacks the recorded boot step, HostWork shall keep admission closed. | Compatible unstamped peer is refused; no Agent starts. |
| CL-HOST-REQ-011 | While provider readiness is unresolved, replacement recovery shall keep Agent activation blocked. | Provider inspection failure leaves the previous Agent stopped and the replacement host empty. |
| CL-HOST-REQ-012 | When an owned release still has claims, HostWork shall retain the resource. | Live declared subscriber and claim survive release; stop and reconciliation then finish release. |
| CL-HOST-REQ-013 | Before provider deletion, HostWork shall confirm its cleanup receipt in the scope journal. | Held and lost `deleting` replies cause no provider release call. |
| CL-HOST-REQ-014 | After a saved cleanup receipt, HostWork shall settle an absent resource without a live host response. | Lost release and inspection replies, removed guard, abrupt owner loss, then successful inspection recovery. |
| CL-HOST-REQ-015 | When a borrowed host is released, HostWork shall retain its infrastructure. | The same fake resource and real host guard remain alive; no service acquire or release effect occurs. |
| CL-HOST-REQ-016 | When a host progress caller is not the accepted task, Service shall reject the update. | Unrelated caller cannot change progress or recovery result. |
| CL-HOST-REQ-017 | When a host guard restarts for the same Core PID, HostRuntime shall reject a different provider boot step. | Guard restart preserves the stamp and rejects a changed or omitted stamp. |
| CL-HOST-REQ-018 | When completed host operation history expires, the scope service shall retain host recovery intent. | Epoch expiry, abrupt owner loss, failed inspection, and a second successful recovery. |
| CL-HOST-REQ-019 | While a release remains unresolved, the scope service shall reject a new release identity for that host. | Fresh release token is refused while the original release retains claims. |

Evidence is in [provider service tests](../../../test/jido_cluster/distributed/host_provider_service_test.exs),
[session tests](../../../test/jido_cluster/host_session_test.exs),
[guard tests](../../../test/jido_cluster/host_control_test.exs), and the earlier
[provider contract tests](../../../test/jido_cluster/host_provider_test.exs).
The focused command passes 29 tests with seed 0 in 11.2 seconds. Its log is
`/tmp/jido-cluster-s6-identity-focus.log`. The peer cases use real Core Agents,
Signals, federation bindings, and host guards, with a controlled provider and
journal. The provider starts the guard with the accepted step. The fixture
checks resource, claim, process, and peer cleanup. This is not Docker evidence.

The service test file also runs a real Bedrock case. It loses the provider acquire
reply, kills the scope owner, restarts the Bedrock repository, and adopts the same
resource without another acquire call. It deploys a declared subscriber, commits
an event, kills the owner and restarts Bedrock again, then restores the same Ref
with a new Agent PID and the committed event. A fresh event arrives after recovery.
Stop and release leave the exact resource identity in a released Bedrock record.
Agent checkpoints use shared Mnesia in this test; the scope journal uses Bedrock.
All 13 peer service cases pass with seed 0 in 15.5 seconds. The log is
`/tmp/jido-cluster-s6-service-bedrock.log`.

Remaining S6 work: real Docker adapter and prepared release, backend contract
tests, all five living examples, the provider cumulative example, and the final
requirement audit. No Docker backend or living example is promoted by these tests.

Complete verification after this increment: `mise exec -- mix test.all` passes
336 tests with seed 0 in 139.2 seconds. `mix quality` passes for 150 modules with
complete documentation/specification coverage. Production compilation with
warnings-as-errors passes. All 33 existing example source/README/test pairs,
their direct or inherited tags, local documentation links, and `git diff --check`
pass. Logs use `/tmp/jido-cluster-s6-service-{all,quality,prod}.log`.
The documentation build also passes without warnings; its log is
`/tmp/jido-cluster-s6-service-docs.log`.

## Local Docker Engine adapter

The [Docker adapter](../../../lib/jido_cluster/host_provider/docker.ex) now calls
the local Engine API through optional Req. This increment has controlled HTTP
evidence. It has not created a real container. The previous LitterBox decision
still applies: no sandbox API, terminal API, image builder, or workspace API is
added. The application supplies a trusted prepared image and network setup.

The API routes and response status handling follow the
[Docker Engine v1.47 specification](https://docs.docker.com/reference/api/engine/version/v1.47.yaml).
Creation supplies a deterministic name. Start and removal address an immutable
container ID. Removal explicitly sets `force=true` and `v=false`. Listing uses
scope labels, includes stopped containers, and requests one more than the accepted
limit so overflow is visible. The adapter inspects each returned candidate before
it returns a Resource. Discovery does not grant release authority.

Configuration requires an explicit Unix socket or loopback HTTP endpoint, the
expected Engine `/info` ID, and either a string-keyed `container` create object or
a full `borrowed_id`. The create object is at most 64 KiB before adapter metadata.
JSON round-trip checks reject atom-keyed objects that could bypass validation.
AutoRemove and reserved `JIDO_CLUSTER_HOST_` environment keys are refused.
Borrowed mode rejects acquire and release calls before any HTTP request.

The prepared application receives `JIDO_CLUSTER_HOST_STEP` as JSON and
`JIDO_CLUSTER_HOST_NODE` as its configured node name. It starts HostRuntime with
the step record. Cookie, address, code, and persistence setup remain application
configuration. A running container does not prove that this runtime is ready.
Failed start leaves the resource inspectable and the service uncertain.

Each callback checks Engine identity before resource inspection. A changed Engine
cannot report absence for the previous Engine. Endpoint identity must remain
stable during a callback; moving a socket or proxy between Engines is outside
this local adapter contract. Runtime options and Engine response bodies are not
included in returned error details or resource records.

HTTP retries and redirects are disabled. Connect, pool, receive, and request waits
have finite configured limits: 1000 ms by default, from 10 to 10,000 ms. Response
bodies stop at 256 KiB. Acquire makes at most five API requests, inspect two,
release three, and discovery at most the accepted limit plus two. Discovery accepts
1–32 candidates. These are phase/request bounds, not one total callback deadline.

An unknown create reply leaves the original scope step attempted. Service recovery
inspects that step; it does not call create again. A create-name conflict is also
inspected without another start. Release checks the exact ID, step, and incarnation
before deletion. A late start request for a deleted ID cannot create another
container. Absence after an unobserved unknown creation remains uncertain in the
service. This stateless adapter does not keep tombstones for direct manual calls
that repeat acquisition after deletion; the scope journal owns that restriction.

| Requirement | Required behavior | Controlled evidence |
| --- | --- | --- |
| CL-HOST-REQ-020 | When Engine identity differs from configuration, Docker shall reject the resource observation. | Changed Engine test makes no container inspection request. |
| CL-HOST-REQ-021 | When a create reply is lost, Docker shall return an indeterminate result without an HTTP retry. | A closed response yields exactly one create request; later inspection returns its step. |
| CL-HOST-REQ-022 | Before deletion, Docker shall verify the exact resource ID and incarnation. | Changed ID, stale incarnation, malformed labels, and wrong step produce no delete request. |
| CL-HOST-REQ-023 | While borrowed mode is configured, Docker shall reject acquire and release effects. | Existing unlabelled resource can be inspected; acquire and release make no HTTP request. |
| CL-HOST-REQ-024 | When a response exceeds 256 KiB, Docker HTTP shall stop body collection and return a limit error. | Oversized response test. |
| CL-HOST-REQ-025 | When an Engine does not answer within the configured HTTP limits, Docker HTTP shall return unavailability. | Server holds the response; the call returns with a 50 ms configured timeout. |
| CL-HOST-REQ-026 | When discovery finds more than the accepted candidate limit, Docker shall return a limit error. | Limit-plus-one listing test; no excess candidate inspection. |

The [12 adapter tests](../../../test/jido_cluster/docker_provider_test.exs) use
a real local HTTP server over TCP and a Unix socket. They check response loss,
partial boot, conflict inspection, exact delete requests, borrowed mode, Engine
changes, malformed observations, response limits, timeout, and discovery. Socket
and server cleanup are checked. They pass with seed 0 in 0.3 seconds. Quality
passes for 153 modules with complete doc/spec coverage. These are protocol tests,
not evidence of actual container creation, BEAM connectivity, or deletion.

Next: prepare the trusted worker image and test network, run the real adapter
contract and five living examples, and add the provider cumulative example.
The OrbStack restart request is still pending. No daemon restart is authorized
by elapsed time, and no real Docker acceptance is inferred from these tests.

Prepared-runtime candidate for the next increment: use host networking and a
unique BEAM node at `127.0.0.1`, with the same trusted cookie as the isolated
control peers. OrbStack documents bidirectional localhost access and shared port
space in [host networking](https://docs.orbstack.dev/docker/host-networking).
The proposed worker release disables automatic EPMD startup and uses the existing
host EPMD. This is an inference for the test setup, not verified connectivity.
Check EPMD registration, two-way node connection, runtime identity, and actual
Agent work against Docker before accepting the setup. Do not change shared
OrbStack network settings to make a test pass.

Full verification after the adapter increment: 348 tests pass with seed 0 in
143.8 seconds. Quality passes for 153 modules. Production compilation with
warnings-as-errors and the documentation build pass. Logs use
`/tmp/jido-cluster-s6-docker-{all,quality,prod,docs}.log`. Local documentation
links, all 33 existing example pairs, and `git diff --check` pass. The socket
probe still times out; real Docker acceptance has not run.


## Prepared worker and first living examples

The [prepared worker fixture](../../../test/fixtures/docker_host/README.md)
now has a separate Mix application, release configuration, a source staging
script, and a Dockerfile pinned to Elixir 1.19.5 and OTP 28.3.1 by image digest.
The script copies the four local V3 package sources without changing them.
The fixture starts Core and HostRuntime with the exact accepted provider step.
It joins existing Mnesia storage when configured; it does not create storage.
Only bounded trusted control-node and table names become atoms. The supervisor
retains only bootstrap fields and excludes the cookie and unrelated environment.

Two [native runtime tests](../../../test/jido_cluster/distributed/docker_runtime_test.exs)
verify the step, namespace, shared persistence identity, new runtime incarnation,
committed Agent restore, invalid bootstrap rejection, unstamped borrowed startup,
and checked Core, guard, and Agent cleanup. They pass with seed 0 in 1.3 seconds
(`/tmp/jido-cluster-s6-docker-runtime-focus.log`). The prior full suite passes
350 tests in 139.2 seconds. Quality passes for 153 modules. The exact fixture Mix
file is excluded from test discovery to remove its nested-project loader warning.
These tests do not prove Linux container startup.

The staged consumer compiles in production with warnings-as-errors and assembles
a native release. That release can load the fixture Runtime while both Req and
Bedrock are absent. This is actual optional-dependency absence evidence, separate
from the SDK's development dependency graph. The logs are
`/tmp/jido-cluster-s6-docker-fixture-{deps,compile,release}.log`. The Linux image
build, EPMD registration, two-way Docker connectivity, and real cleanup remain
unverified. No container or daemon restart was performed.

| Example | Implemented controlled claim | Required real-provider evidence |
| --- | --- | --- |
| [09_01 Acquired topology](../../../examples/09_host_providers/09_01_acquired_topology/README.md) | Closed admission before acquisition, committed federation delivery, retained resource while claims exist, process cleanup, and final released identity in Bedrock. | Actual container startup and deletion after the same lifecycle. |
| [09_02 Lost acquire reply](../../../examples/09_host_providers/09_02_lost_acquire_reply/README.md) | Abrupt owner loss and real Bedrock restart retain the step. Failed inspection keeps admission closed. Later inspection adopts one resource with no second acquire call. | One actual container after response loss and recovery. |
| [09_03 Borrowed and incompatible hosts](../../../examples/09_host_providers/09_03_borrowed_and_incompatible/README.md) | Borrowed infrastructure remains, with no service acquire/release effect. Wrong namespace starts no Agent; explicit owned cleanup remains available. | Actual borrowed container retention and incompatible owned container cleanup. |

The four tagged tests pass with seed 0 in 9.9 seconds
(`/tmp/jido-cluster-s6-examples-focus.log`). They use real Bedrock for scope state,
shared Mnesia for Agent checkpoints, native peers, and the controlled provider.
Every case checks Agent, channel, claim, provider inventory, and process cleanup
as applicable. The borrowed fixture removes its externally owned resource only
after the retention assertions. Fake inventory deletion does not prove VM exit.

The delayed-create service test adds direct evidence for CL-HOST-REQ-007. A
provider call returns unknown before its effect. Release sees absence and stays
uncertain, including after abrupt owner restart. The fixture then completes the
original create. Reconciliation adopts and removes that exact resource with one
acquire call and one release call. No SDK change was needed for this test.

Still required: `09_04_release_guard`, `09_05_abrupt_death_cleanup`, the prepared
Linux build, the real Docker backend and example suite, `11_02` provider cumulative
acceptance, and the final requirement audit. S6 remains incomplete. S7 has not
started. OrbStack restart approval remains pending.


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


## Cleanup examples and explicit Docker runner

[09_04 Release guard](../../../examples/09_host_providers/09_04_release_guard/README.md)
uses a live two-way partition to hold confirmation of required binding cleanup.
The remote mirror stays alive, claims remain, and no provider delete call occurs.
Reconnect and reconciliation settle the same stop and release requests. A second
case replaces the provider observation at the same step with a different resource
ID and incarnation. Both a stale direct release and scope release preserve that
replacement. External fixture cleanup runs only after preservation assertions.

[09_05 Abrupt death cleanup](../../../examples/09_host_providers/09_05_abrupt_death_cleanup/README.md)
uses one control peer and four workers. Real Bedrock commits a `deleting` receipt
but its reply is lost. Before recovery, no provider delete effect occurs. The test
kills the owner without termination callbacks, restarts Bedrock, and reconciles.
Only the exact target resource is deleted. An independent live resource remains;
its Agent restarts at the same Ref with committed state and receives a new event.
Borrowed capacity and its guard remain. A changed-incarnation candidate remains
uncertain with the original saved handle. The target deployment stays stopped.
The test then checks cleanup of the independent workload and fixture controls.

These cases complete the controlled versions of the five S6 examples. Their
provider resources are records in a controlled fixture. A replacement observation
does not replace a VM. These results do not prove actual Docker resource lifetime.
They directly exercise CL-HOST-REQ-003–005, 012–015 and CL-CLEAN-REQ-001–003 with
real journal restart and native Agent/federation processes.

`mise exec -- mix test.docker` now explicitly selects
[Docker acceptance](../../../test/jido_cluster/distributed/docker_acceptance.exs).
It requires a socket and prepared image, checks the Engine, and pins the existing
local image ID before resource creation. The cases use only `:peer`; their file
is outside the default test pattern. Missing prerequisites invalidate the cases
and return exit 2, as verified by `/tmp/jido-cluster-s6-docker-prerequisite.log`.
This is runner-selection evidence, not Docker acceptance. The direct Engine ping
still times out after five seconds. No daemon restart is authorized or performed.

The prepared cases cover real runtime connection, provider boot identity, committed
Agent restore, duplicate acquisition, discovery, borrowed and stale-handle effect
refusal, incompatible runtime observation, and exact deletion. Cleanup is registered
before acquisition and uses unique namespace labels plus exact step/ID checks.
Read the [worker instructions](../../../test/fixtures/docker_host/README.md#explicit-docker-acceptance)
for the command. Real Engine execution, the remaining backend faults, real versions
of all five living examples, the provider cumulative variant, and the final S6
audit remain required. S7 has not started.


The configured Docker invocation also returns exit 2 with two invalid cases after
Engine inspection times out in 5.1 seconds
(`/tmp/jido-cluster-s6-docker-unavailable.log`). It creates no resource. The explicit
filename has a narrow documented Credo filename exception so it remains outside
default discovery on both Elixir 1.18 and 1.19. Quality passes for 173 modules with
complete documentation/specification coverage. All 38 stable example pairs have
matching folders and correct direct or inherited tags; local links pass.


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


## Provider cumulative preparation and expanded Docker cases

[11_02 Provider lifecycle](../../../examples/11_system/11_02_provider_lifecycle/README.md)
now runs the same [cumulative scenario](../../../test/examples/support/system_lifecycle_scenario.ex)
as the static S5 example. Both static and controlled-provider variants pass in
managed and attached Core modes: four tests, seed 0, in 16.4 seconds
(`/tmp/jido-cluster-s6-provider-system.log`). Extracting the shared scenario retained
the existing S5 assertions and added provider observations at recovery and partition
boundaries. The provider version is not a reduced lifecycle.

The controlled provider prepares two owned shared workers and one borrowed
independent worker. Initial admission requires successful acquisition/inspection.
The scenario checks pending Ref visibility, a partial drain receipt, actual Agent
exits on owner loss, committed state restore, stopped intent, retained uncertain
claims during a live partition, independent work, recovered bindings, and fresh
delivery. Exact provider identities remain unchanged. No extra acquisition occurs
after restart. Final release follows all Agent and binding cleanup: only the two
owned resources are removed, and borrowed capacity and its guard remain. Bedrock
records two released sessions and one retained session. Fixture cleanup then stops
its own remaining resources. This is controlled provider evidence, not proof of
container deletion. The required real Docker cumulative run remains incomplete.

The explicit Docker file now has four prepared cases. It adds failed-bootstrap
inspection and a real Engine/Bedrock service-recovery path. The latter records the
exact step before calling Docker, withholds the successful acquire reply, kills
the scope owner, restarts Bedrock, adopts the same resource without a second
acquire call, commits a federated event, and requests scope release. It asserts
actual absence before fixture cleanup and compares the released Bedrock record
with the original resource. The
[reply-loss fixture](../../../test/support/docker_reply_loss.ex) retains only steps,
calls, and its one-shot fault state; it stores no Docker options or cookie.

The worker fixture includes a small declared federation topology for that backend
case. A separate staged production consumer compiles it with warnings-as-errors.
The explicit file compiles and selects four cases, then correctly returns exit 2
when prerequisites are absent (`/tmp/jido-cluster-s6-docker-expanded-prerequisite.log`).
All four cases are invalid in that run, not passed. Container execution is still
required. The worker image does not yet include the five example definitions or
the cumulative definitions, and the Docker example runners remain to be built.
No Linux image build, Engine restart, or container creation is claimed here.

Quality passes for 178 modules with complete documentation/specification coverage
(`/tmp/jido-cluster-s6-provider-system-quality.log`). S6 remains incomplete until
the actual Docker backend and full example/cumulative lifecycle are verified.
S7 has not started. The OrbStack restart request remains unanswered.


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

## Real Docker acceptance and S6 audit

The Docker Engine began responding on 2026-09-16 without a restart. A Linux
worker image built from staged local V3 sources and the pinned base image. Its
local ID is `sha256:763a2867b42f799b9c05a10fc3c47951e37190e5f2d8bb778a706e242c138a7f`.
The build includes the declared example modules and the worker visibility
barrier. It does not copy test runners or a cookie into the image.

`mise exec -- mix test.docker` passes five real backend cases with seed 0 and
zero failures (`/tmp/jido-cluster-s6-real-backend-final.log`). They cover exact
step creation and deletion, lost acquisition reply and Bedrock restart, duplicate
acquisition, incompatible and failed boot, bounded discovery, borrowed inspection,
and independent worker access during a visible node partition. The adapter's
HTTP tests remain in the default suite.

`mise exec -- mix test.examples.docker` passes nine real cases with seed 0 and
zero failures (`/tmp/jido-cluster-s6-real-examples.log`). The seven numbered
provider cases call the same scenario functions as the controlled examples.
The two [cumulative Docker cases](../../../test/examples/11_system/11_02_provider_lifecycle/docker_acceptance.exs)
call the same [system scenario](../../../test/examples/support/system_lifecycle_scenario.ex)
as the native managed and attached modes. After a fixture-only refactor, both
cumulative cases pass again (`/tmp/jido-cluster-s6-real-system-final.log`).

| Living example | Source | Controlled and Docker tests |
| --- | --- | --- |
| 09_01 acquire and use a host | [README](../../../examples/09_host_providers/09_01_acquired_topology/README.md) | [native](../../../test/examples/09_host_providers/09_01_acquired_topology/acquired_topology_test.exs), [Docker](../../../test/examples/09_host_providers/09_01_acquired_topology/docker_acceptance.exs) |
| 09_02 adopt a lost reply | [README](../../../examples/09_host_providers/09_02_lost_acquire_reply/README.md) | [native](../../../test/examples/09_host_providers/09_02_lost_acquire_reply/lost_acquire_reply_test.exs), [Docker](../../../test/examples/09_host_providers/09_02_lost_acquire_reply/docker_acceptance.exs) |
| 09_03 borrow and reject incompatibility | [README](../../../examples/09_host_providers/09_03_borrowed_and_incompatible/README.md) | [native](../../../test/examples/09_host_providers/09_03_borrowed_and_incompatible/borrowed_and_incompatible_test.exs), [Docker](../../../test/examples/09_host_providers/09_03_borrowed_and_incompatible/docker_acceptance.exs) |
| 09_04 guard release and replacement | [README](../../../examples/09_host_providers/09_04_release_guard/README.md) | [native](../../../test/examples/09_host_providers/09_04_release_guard/release_guard_test.exs), [Docker](../../../test/examples/09_host_providers/09_04_release_guard/docker_acceptance.exs) |
| 09_05 recover abrupt cleanup | [README](../../../examples/09_host_providers/09_05_abrupt_death_cleanup/README.md) | [native](../../../test/examples/09_host_providers/09_05_abrupt_death_cleanup/abrupt_death_cleanup_test.exs), [Docker](../../../test/examples/09_host_providers/09_05_abrupt_death_cleanup/docker_acceptance.exs) |
| 11_02 combined lifecycle | [README](../../../examples/11_system/11_02_provider_lifecycle/README.md) | [native](../../../test/examples/11_system/11_02_provider_lifecycle/provider_lifecycle_test.exs), [Docker](../../../test/examples/11_system/11_02_provider_lifecycle/docker_acceptance.exs) |

Real replacement tests found that cleanup tried to query a worker after its
container had disappeared. [HostWork](../../../lib/jido_cluster/instance/host_work.ex)
now rejects a different observed identity before checking runtime cleanup. If
the exact recorded resource is authoritatively absent and no claim remains, it
can settle release without asking the dead worker. An unrecorded acquisition
remains uncertain, and no scope call deletes a replacement incarnation. The
three affected Docker examples then pass with actual preserved and removed IDs.

The cumulative case gives each Docker worker a RAM copy of the shared Agent
table after startup, as the native system fixture does. It checks table access
and a stable healthy node group while the target stays isolated. This preserves
independent work and committed state during the partition. Managed and attached
Core modes each pass with three real containers. The scope removes only its two
owned containers; the borrowed container, Core, and guard remain until the
external fixture performs exact final cleanup. Docker reports no remaining
Cluster-labelled containers after the tests.

The default suite passes 371 tests with seed 0 and zero failures
(`/tmp/jido-cluster-s6-real-default.log`). Four native cumulative cases pass
after the last fixture refactor (`/tmp/jido-cluster-s6-real-system-native-final.log`).
Quality passes for 178 modules with complete documentation and specification
coverage (`/tmp/jido-cluster-s6-real-quality.log`). Production compilation and
documentation generation pass without warnings
(`/tmp/jido-cluster-s6-real-{prod,docs}.log`). An isolated production consumer
compiled and started Cluster with `Req` and `Bedrock` both absent
(`/tmp/jido-cluster-s6-optional-run.log`).

A dedicated [Docker CI job](../../../.github/workflows/ci.yml) builds the prepared
worker image and runs both explicit Docker aliases on Linux. This local worktree
has not been pushed, so no remote CI result is claimed. The local acceptance
proves the S6 behavior on this Engine. S6 implementation and local acceptance
are complete; the design review remains Pending approval. S7 is next.
