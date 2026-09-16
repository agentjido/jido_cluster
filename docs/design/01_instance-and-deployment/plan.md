# S1 — OTP instance and static deployment

Status: proposed implementation plan. Written on 2026-09-15. No implementation
or passing evidence is claimed here. See [scope and dependencies](README.md).

## Outcome

Run a named Cluster instance with `use Jido.Cluster`, deploy a supported core
topology onto static hosts, and inspect its lifecycle. Preserve the current
Scheduler and keyed-manager APIs. Support root singleton topologies only.

## Implementation steps

1. Add instance contract tests before changing supervision. Cover macro defaults,
   application configuration, child-start overrides, and stable instance identity.
2. Add `Config` and the instance macro with `child_spec/1`, `start_link/1`, and
   configuration inspection. Validate namespace, capacity scope, pools, and names.
3. Build managed and attached core modes. Managed core starts before dependent
   services. Attached core must already exist and remains application-owned.
4. Extract a deployment owner from the existing Scheduler lifecycle. Preserve its
   connected ownership claim, manual Controller, and confirmed cleanup barrier.
5. Add facade operations for plan, deploy, status, Ref lookup, call, operation
   lookup, await, and stop. Reuse core identities and public Controller reads.
6. Add request IDs to placement-changing calls. Bind each ID to its action and
   normalized input. Same request returns the same operation; changed input fails.
7. Add one static deployment example in both managed and attached modes.

## Contracts and lifecycle

Use one local Registry and deployment supervisor per instance. Keep operation
records in explicit memory-only development mode until S3. Status must identify
that limitation. Validate the default Bedrock adapter configuration, but reject a
request for durable operation guarantees before S3; do not imply durability from
successful configuration alone.

Use namespace plus scope ID for capacity ownership, and namespace plus core
topology ID for deployment ownership. Do not derive identity from transient PIDs.
Separate operation acceptance from core readiness. Await timeout does not cancel
an operation. Ref calls never automatically replay a Signal.

## Failure handling

- Invalid or unsupported topology: reject before any Controller or Agent starts.
- Missing attached core or namespace conflict: fail startup without changing core.
- Core loss: block mutations, settle ownership cleanup, then reconcile.
- Stop failure: retain ownership and report uncertainty; do not claim completion.

## Tests and completion

Unit tests cover config precedence, validation, and request conflicts. Peer tests
cover competing owners and stable Ref routing. Test managed startup/shutdown and
prove that stopping attached Cluster retains external core. The example plans,
deploys, waits, calls, inspects, and stops.

Done when these tests and existing examples pass, the facade reports memory-only
limits, and cleanup has no orphaned owned Controller or Agent.

Write the unit contracts first, then local peer tests, then the tagged living
example. Run relevant package format, compile, quality, and test checks. Record
actual results and evidence links here before marking this slice complete.

## Example-based acceptance plan

Status: planned examples; none are created or proved by this document. Follow the
[shared example test method](../00_architecture/example-testing.md).

Proposed group: `examples/04_deployment/`, mirrored under
`test/examples/04_deployment/`. These numbers extend the existing 01–03 groups;
confirm they remain free before implementation. Keep scenario IDs stable once added.

### Setup

Use one control node and two worker peers with the same namespace. Define a
small root-singleton topology whose Agent records a count and last event ID.
Use explicit development storage; S1 does not prove durable journal recovery.

### Scenarios

| Proposed example | Actions | Required observations |
| --- | --- | --- |
| `04_01_managed_instance` | Start `use Jido.Cluster` without `jido:`; plan, deploy, await, call by Ref, then stop. | Planning creates no Agent. Accepted and ready are distinct. Core starts before deployment. Owned Agents and managed core stop with the instance. |
| `04_02_attached_instance` | Start external core, attach Cluster, deploy and call, then stop Cluster. | Owned topology processes terminate; external core remains usable. Missing core and conflicting namespace fail without affecting it. |
| `04_03_request_identity` | Hold activation at a test barrier; submit the same request from independent callers, then release. | Both callers observe one operation and one activation. Changed payload conflicts. Await timeout does not cancel or duplicate the operation. |

### Evidence and failure control

Record the core instance PID and topology PIDs through public APIs, then monitor
termination. To prove startup count, use a test Agent lifecycle notification; do
not infer absence solely from an empty location cache. Keep activation barriers
in test support, never in the published Agent's domain actions.

### Promotion record

For each scenario, add links to its source, README, and executable test. Record
the command, seed, backend, result, and cleanup result. Map every README guarantee
to an assertion. A fake-only result cannot prove an external backend contract.
Keep this slice incomplete until its required examples and lower-level contracts
pass; record unavailable cases explicitly.

## Cross-slice refinements

Follow [the lifecycle contracts](../00_architecture/lifecycle-contracts.md).
Implement the owned-host runtime handshake on peers here, before provider work.
Test namespace/protocol rejection, incarnation change, and rejoin with existing
activations. Define managed-core naming and attached-mode dependencies once.

Add lifecycle variants for deployment stop, orderly service shutdown, and a
coordinator crash. Stopped intent and preserved running intent are different.
Process cleanup remains mandatory before reactivation; uninterrupted workers are
not promised. Durable restart behavior is gated on S3.

Before freezing facade identities, run the early S7 workload/Ref mapping probe.
Record scope, operation identity, claim ownership, and journal boundaries alongside
S2 design. S1's memory-only stage is an internal increment, not a durable release.

## Final build refinements

Use the [build gates](../00_architecture/build-readiness.md) before adding the
facade. Define a host-local claim-guard boundary alongside registration, and expose
pending directory observations explicitly. Test that an intentional deployment stop
cannot be reversed by automatic child restart. Add correlated operation/attempt
status now so later failure examples can use public observations.

## Decisions and limits

Choose exact facade return structs and the derived managed-core name before the
first implementation commit. Record them in this folder. Preserve the current
Scheduler facade during migration; do not change core merely to add this wrapper.

## Implementation record — first increment

Implementation is in progress. This record does not promote S2–S7 or claim a
durable release. Review status remains pending approval.

The named instance uses `Module.concat(ClusterModule, Core)` for managed core.
Attached mode inherits the live core namespace and rejects an explicit conflict.
Configuration order is module, application, then start options. Journal storage
is explicit `:memory` in this increment; selecting the default Bedrock adapter
validates its prerequisites and cannot silently select memory. Durable operation
storage still requires S3. Agent persistence is a separate option and attached
mode cannot change it.

`Jido.Cluster` now exposes `config`, `status`, `plan`, `request_id`, `deploy`,
`operation`, `await`, `ref`, `lookup`, `call`, and `stop`. Operations are maps with
operation ID, attempt ID, scope, namespace, topology ID, phase, and reason. Request
tokens carry scope, generation, retention epoch, and a UUID nonce. A token from
another generation is expired. This memory-only generation does not survive
service restart. Retention bounds and durable epochs remain S3 work.

The instance has a local Registry, deployment supervisor, operation supervisor,
and connected scope owner. Slow deployment work runs outside the scope handler.
The existing Scheduler and its independent cleanup owner remain the deployment
mechanism. A service crash stops this memory-only instance. It cannot silently
restart an empty admission authority. Core starts first and stops last in managed
mode. The same core name is required on remote static hosts.

HostRuntime reports protocol 1, namespace, release identity, persistence adapter
identity, services, host ID, and a fresh incarnation. Direct probes check required
Agent modules. Control loss closes the guard. Explicit reconciliation is required
before registration can reopen. S2 must add allocation and claim confirmation;
this initial guard does not yet enforce shared capacity or claim recovery.

Evidence:

- `test/jido_cluster/instance_test.exs`: configuration, ownership modes, collisions,
  and missing prerequisites.
- `test/jido_cluster/deployment_test.exs`: pure planning, request binding, Ref
  lookup, stop, and shutdown cleanup. A forged plan test requires reconstruction
  through core before deployment.
- `test/jido_cluster/host_runtime_test.exs`: compatibility, incarnation, and
  control-loss guard behavior.
- `test/jido_cluster/distributed/instance_test.exs`: connected owner exclusion,
  abrupt service loss, and attached core loss on separate local Erlang peers.
- `test/examples/04_deployment/`: managed, attached, and duplicate-request examples.
  The request example uses a storage barrier before Agent startup and independent
  peer calls. It checks one active Agent and remote cleanup.

Baseline: Cluster `6559c2e`, core `01863527`, Signal `8d361df`, Action `04288be`.
Core is on `feat/plugin-facets-only` with concurrent uncommitted changes. Signal
is on `fix/open-issue-cleanup`. Branches were retained and local paths were used.
`mise exec -- mix deps.get`, compile with warnings as errors, and the baseline
`mix test.all` passed. Focused instance, host, peer, and example tests used seed 0.
Docker client and server were available; no provider behavior is proved by that
availability check. No real Bedrock integration has run in this increment.

Core-loss testing exposed a Registry dependency during cleanup. The Cluster owner
now stops its known Controller directly. Core loss can also remove core's cleanup
observer before the settlement event. Actual Agent exit was observed, but Cluster
retains the owner when the acknowledgement is missing. The service blocks new
work and finishes bounded shutdown; it does not authorize replacement. Durable
reconciliation of that retained uncertainty remains S3 work.

Remaining S1 refinements include bounded operation retention, fuller host protocol
fault coverage, and lifecycle reconciliation integration. Shared budgets, journal,
federation, providers, and entity activation are not implemented by this increment.
