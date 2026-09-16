# S2 — Shared capacity and drain

Status: proposed implementation plan. Written on 2026-09-15. No implementation
or passing evidence is claimed here. See [scope and dependencies](README.md).

## Outcome

Share one capacity budget across topology deployments. A host listed in several
pools still has one slot inventory. Drain a host across all managed deployments.

## Implementation steps

1. Write pure claim-accounting tests, including pool aliases and transition slots.
2. Add canonical host IDs and validate a host's capacity once per admission scope.
3. Add one connected admission owner. Serialize reservations and releases there;
   deployment workers perform slow core operations outside its message handler.
4. Reserve the complete initial plan before activation. Convert reservations to
   accepted claims only from confirmed core outcomes.
5. Add a scope-wide drain operation. Mark the host unavailable for new placement,
   calculate target capacity, then execute bounded deployment moves.
6. Retain both source and target claims through uncertain movement. Release claims
   only after confirmed retirement or confirmed absence of activation.
7. Add competing admission, shared cleanup, and multi-deployment drain examples.

## Contracts and lifecycle

Claim identity includes scope, topology, core Agent Ref, host incarnation, and
placement operation. Capacity is an integer Agent-slot budget, not measured CPU.
Reject overlapping independently owned scopes unless their budgets are explicitly
partitioned. Unmanaged processes do not count as managed claims.

Serialize claim updates through admission and execute operations under explicit
resource reservations. An uncertain operation retains claims but releases its
execution slot. Independent capacity remains usable. Conflicting requests return
bounded, explicit busy/uncertain errors. Keep completed drain exclusion until an
explicit re-enable operation; defer cancellation of in-flight drains.

## Failure handling

- Insufficient initial capacity: start no Agents.
- Partial activation failure: release only claims whose cleanup is confirmed.
- No transition capacity: reject movement before starting it.
- Source or coordinator loss: retain uncertain claims; no timed-out replacement.

## Tests and completion

Race two deployments for one slot on separate control callers. Observe actual
Agent starts as well as counters. Stop one of two shared deployments and verify
the other remains. Drain both and verify stable Refs, restored state, and no new
placement on the source.

Done when admitted claims cannot exceed scope capacity through those operations.
Restart durability remains an explicit gap until S3.

Write the unit contracts first, then local peer tests, then the tagged living
example. Run relevant package format, compile, quality, and test checks. Record
actual results and evidence links here before marking this slice complete.

## Example-based acceptance plan

Status: planned examples; none are created or proved by this document. Follow the
[shared example test method](../00_architecture/example-testing.md).

Proposed group: `examples/05_shared_capacity/`, mirrored under
`test/examples/05_shared_capacity/`. These numbers extend the existing 01–03 groups;
confirm they remain free before implementation. Keep scenario IDs stable once added.

### Setup

Use two topology instances, three worker peers, and one capacity scope. Label
hosts so initial placement and drain targets are deterministic. Give the source
capacity for both workers and reserve enough target slots for cooperative moves.

### Scenarios

| Proposed example | Actions | Required observations |
| --- | --- | --- |
| `05_01_last_slot` | Release two deployment requests together from independent peer callers for one remaining slot. | Exactly one is admitted and starts. The rejected topology starts no Agent. Claim totals and observed starts agree. |
| `05_02_shared_host` | Deploy two topologies on one host; stop the first and call the second. | Only the stopped topology releases claims. The shared host and second worker remain active. |
| `05_03_shared_drain` | Commit different state to both workers; drain the source while attempting a new deployment. | Both Refs retain their state after movement. The source accepts no new placement. Drain completes only after target readiness and source retirement. |
| `05_04_transition_capacity` | Fill target slots, request drain, then add adequate capacity and retry explicitly. | The first attempt starts no move and changes no committed state. The later accepted attempt stays within the configured claim budget. |

### Evidence and failure control

Use public claim/status inspection plus monitored Agent starts and exits. Assert
source and target claims at a controlled intermediate movement barrier. Run both
possible admission winners as valid outcomes; do not depend on scheduler timing.
An ordinary actor message barrier does not prove all nodes have settled.

### Promotion record

For each scenario, add links to its source, README, and executable test. Record
the command, seed, backend, result, and cleanup result. Map every README guarantee
to an assertion. A fake-only result cannot prove an external backend contract.
Keep this slice incomplete until its required examples and lower-level contracts
pass; record unavailable cases explicitly.

## Cross-slice refinements

Use [the capacity and reservation contracts](../00_architecture/lifecycle-contracts.md).
Replace scope-wide operation blocking with serialized ledger updates and explicit
resource conflict sets. Execution concurrency may start at one; uncertain operations
release that slot but retain unresolved claims. Journal loss still blocks all writes.

Add a host-allocation registration contract with connected scope ownership. Reject
known conflicting registrations and aliases that would double capacity. Legacy
Schedulers and unmanaged processes require disjoint budgets; do not claim detection
of arbitrary external use or partition-safe enforcement.

Add `05_05_independent_progress`: leave a drain uncertain on allocation A, then
admit and complete work on disjoint allocation B. Verify retained claims on A,
correct rejection of conflicting work, and public reasons for each decision.
Repeat after restart in S3. Design journal transition boundaries with S3 now so
reservation identity does not change when persistence is added.

## Final build refinements

Apply the [Hyper-derived admission requirements](../00_architecture/lifecycle-contracts.md#final-refinements-from-hyper-review).
Test a stale candidate report, changed host incarnation, host-guard restart, and
lost activation response. Admission precedes startup. Retry another candidate only
when the previous attempt is confirmed to have started nothing, or its cleanup is
confirmed. Preserve per-candidate reasons instead of reducing all failures to
insufficient capacity.

Add generated command sequences against a small claim-ledger model. Check slots
remain conserved, duplicate confirmation/release is idempotent, conflicting claims
are rejected, and uncertain claims are never reclaimed solely by timeout.

## Decisions and limits

Retain the existing per-Scheduler API as a separate scope. It must not silently
share or consume the new service's budget. Decide host alias validation and claim
inspection format before coding; automatic load-driven rebalance is excluded.

## Implementation record — shared admission increment

Work is in progress; S2 is not complete. The pure `Jido.Cluster.Admission` ledger
now canonicalizes identical pool aliases, reserves complete Ref demand, retains
uncertainty, accounts for source and target claims, and releases only from an
explicit confirmed-cleanup transition. Generated command sequences compare claim
counts with an independent set model.

The named instance serializes this ledger before starting operation tasks.
Concurrent last-slot deployment tests check both the public claims and the actual
AgentSupervisor child count. A shared-host test stops one deployment and keeps the
other Agent and claim. A caller-supplied placement cannot cause the managed
Scheduler to choose an alternative host: its reservation is exact. Legacy
Schedulers remain on their earlier independent path.

Host confirmation uses the same scope, operation, Ref claim, host incarnation, and
configured budget. `HostRuntime` checks the claim before core activation, rejects
changed budgets, and confirms release only when the exact local Ref is absent.
A live activation prevents release even when the caller reports cleanup. A guard
failure does not authorize fallback to another host. Uncertain confirmation keeps
the scope claims charged. Core Controller replacement is not automatic for these
externally reserved deployments.

Current evidence uses seed 0 in `test/jido_cluster/admission_test.exs`,
`shared_admission_test.exs`, and `host_runtime_test.exs`. The admission suite includes
250 generated commands. These are local unit contracts; multi-node S2 acceptance
examples and host-guard restart faults remain required. S1 peer examples continue
to cover remote activation but do not substitute for the S2 race and drain proofs.

Scope-wide drain now has a pure complete-reservation plan and a peer execution
contract in `test/jido_cluster/distributed/shared_drain_test.exs`. It moves two
deployments, checks stable Refs and committed counts, confirms old Agent exits,
and verifies released source claims and retained drain exclusion.

## Implementation record — uncertainty and examples

The host now retains scope, claim, and capacity records across guard process
restarts. Each VM-local record belongs to one core PID. A new guard incarnation
rejects registration until the caller reconciles the exact retained claim set.
An empty replacement guard is not treated as evidence that no Agent started.
The test kills a guard with a live Agent, checks the retained record, rejects
empty reconciliation, and proves that release still requires Agent retirement.
A new core lifetime does not inherit the prior core record. This is not durable
journal recovery or automatic adoption of prior Scheduler guards.

Operation telemetry now reports operation and attempt IDs, exact claim IDs, and
observed results from the worker task. A lost-result test kills that task after
a real Agent is ready and before the authority gets the result. The Agent stays
active, the claim stays uncertain, and a repeated request does not start another
Agent. Stopped intent with unconfirmed cleanup reports uncertain readiness.

The peer independent-progress test interrupts a drain after target readiness but
before source claim release. Both claims remain charged. A conflicting drain
returns resource identifiers, while work on a separate host completes. The
public `enable_host/3` API removes drain exclusion only through an explicit
idempotent request; uncertain claims and an active source drain reject it.

The [shared-capacity example group](../../../examples/05_shared_capacity/README.md)
is now executable. Its five mirrored `:example` tests cover the last-slot race
through independent peer callers, shared-host cleanup, shared drain, transition
capacity, and independent progress. The transition example adds available
capacity by stopping a target occupant; live budget resizing remains unsupported.
Each example checks empty worker Agent supervisors during cleanup.

Verification after this increment: `mise exec -- mix quality` passes format,
compile, strict Credo, and Doctor. `mise exec -- mix test.all` passes 110 tests
with seed 0. The focused new example group passes all five scenarios. Backends
are explicit memory control state and replicated RAM Mnesia Agent storage.

## Implementation record — partitions and final admission checks

The current memory-stage S2 contracts are implemented. A local core now has one
shared guard. It can declare fixed allocation IDs and limits before services
attach. Each scope selects one allocation per host. A conflicting scope cannot
register the same allocation, and separate partitions cannot confirm the same
core Ref. Pool aliases with implicit and explicit `"default"` IDs count once.
Guard restart retains every partition and requires separate reconciliation.

The tests in `test/jido_cluster/host_partitions_test.exs` cover two scopes on one
core, a conflicting third scope, Ref collisions, restart retention, and shutdown
of one service while the other remains active. The guard monitors core lifetime;
it is no longer owned by one attached Cluster instance.

`test/jido_cluster/distributed/host_candidate_test.exs` checks stale release and
budget reports. Failure records retain the selected host, allocation, check stage,
and reason. Both peers have zero Agent children after rejection; there is no
fallback start. Planning conflicts caused by uncertain eligible claims now return
those claim IDs instead of a generic capacity error.

Drain checks all claims on its source, including arrivals reserved by another
move and claims awaiting stop cleanup. Those cases return busy claim IDs. The
pure planner tests and shared-drain example prevent a second drain from reporting
completion while accepted work can still activate on its source.

Live budget resizing and packing multiple allocations on one node within one
scope remain unsupported. The example adds free capacity by stopping a target
occupant. Durable adoption of retained guard identities belongs to S3, which has
not started. The seven-slice goal remains incomplete.

Final verification for this memory-stage increment: `mise exec -- mix quality`
passes; `mise exec -- mix test.all` passes 116 tests with seed 0; `mise exec -- mix
docs` builds without warnings; `git diff --check` passes. No Bedrock or Docker
verification is included in this result.
