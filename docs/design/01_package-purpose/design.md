# Package purpose and proposed design

Status: proposed. This document selects a direction for review, not an implemented API.

## Purpose

`jido_cluster` should be the distributed placement and recovery control plane for Jido Agents. It should let an application address an Agent by stable identity while the package selects suitable capacity, tracks its current location, and coordinates replacement or movement.

A useful first application is one Agent per tenant session or device. Callers can reach that Agent from any participating node. The Agent retains Jido execution and persistence semantics. The cluster layer decides where it runs and when another activation can replace it.

The current keyed counter is a small proof of routing and checkpoint recovery. It does not prove the complete proposed control plane. See the [example](../../../examples/01_cluster/01_01_keyed_counter/README.md).

## Ownership

| Owner | Owns |
| --- | --- |
| `jido_action` | Actions, Instructions, executable values, and in-memory execution |
| `jido_signal` | Signal envelope, routing, dispatch, and local Bus |
| `jido` | Agent identity, definitions, state transitions, AgentServer, Plugins, local supervision, persistence record encoding, declarative Topology, and exact known-node activation |
| `jido_cluster` | Eligible membership, distributed location, placement selection, admission, movement, replacement coordination, and cluster operations |
| Infrastructure provider | Capacity acquisition, process placement mechanics, status, and capacity release |
| Authority service and protected storage | Ownership grants and rejection of stale holders at protected writes |
| Application or higher orchestration layer | Workflow meaning, business retries, external-effect deduplication, tenant policy, and durable orchestration |

The authority service can be implemented by a cluster adapter or an external system. Its enforcement must occur at the protected operation. A placement provider does not grant durable write authority.

## Three separate values

1. **Identity:** use the core `Jido.Agent.Ref` contract: namespace, optional partition, and ID. Identity survives movement.
2. **Location:** record the current node, process or host, activation generation, readiness, and observation revision. A location can be stale or uncertain.
3. **Authority:** record the exact holder, ownership epoch, and validity rules when a deployment requires exclusive writes. A newer epoch must reject every older holder at protected writes.

Desired placement is another separate value. It records what the policy wants. An observed process is evidence of what exists. It does not prove that desired placement is complete or that the process can still write.

The existing manager/key API can remain an entry point while its relationship to core Refs is designed. Do not silently change existing IDs or storage keys.

## Operating modes

### Connected-node foundation

Keep the current explicit mode: matching managers on connected nodes, rendezvous placement, per-key connected-cluster locks, and restore from shared persistence when available. State the limits in status and documentation.

This mode has no durable writer lease. Membership-count quorum is a local availability check. It cannot alone prove that a disconnected or delayed old writer cannot commit.

### Fenced placement

Propose an opt-in mode backed by an authority contract. Replacement must acquire a newer grant. Storage must reject lower epochs atomically with the protected commit. Loss of confirmed authority must prevent more protected writes.

First determine how this can use the public core persistence contract. Core currently supplies byte or opaque-token compare-and-swap, not an ownership-epoch field. A possible adapter could enforce authority with separate metadata in the same transaction. That requires proof for old activations, deletes, tombstones, maintenance operations, and unknown write results. Do not assume that an adapter option or a Plugin callback is sufficient.

External effects require receiver-side enforcement or application deduplication. Fencing a checkpoint does not fence a payment or tool call that already occurred.

### Dynamic capacity

After static placement and ownership contracts are proved, add a provider for dynamic BEAM hosts. Issue #19 proposes FLAME as the first candidate. Treat this as an optional integration; do not add provider-specific types to core.

A long-lived supervised placement owner must hold the provider lifecycle. A temporary request Task must not own the remote host. Provider lifecycle ownership and durable write authority must have different names and types.

A Sprite used as an external workspace may be an application resource rather than an Agent host. Keep that mode outside the initial cluster runtime scope until its ownership boundary is decided.

## Proposed components

| Component | Purpose | Initial scope |
| --- | --- | --- |
| Membership view | Report eligible hosts, generation, labels, health, and observation revision | Existing connected managers |
| Placement policy | Select a host from requirements and available capacity | Rendezvous placement |
| Admission | Reserve capacity before activation and bound replacement work | Proposed |
| Location directory | Publish versioned identity-to-location observations | Proposed; current API returns temporary PIDs |
| Authority adapter | Obtain and validate grants; enforce stale-writer rejection | Proposed |
| Placement owner | Supervise one placement lifecycle and its provider relationship | Proposed |
| Recovery coordinator | Separate Agent, node, provider, and authority failures; apply bounded repair | Proposed |
| Operator surface | Inspect, drain, move, stop, and preview changes | Proposed |

Avoid a second Topology runtime. For declared Topology Agents, use the public core Controller to apply a selected exact node. For independently keyed Agents, use public core Ref and lifecycle operations. Define which controller owns replacement so both layers cannot repair the same Agent independently.

The current `Jido.Cluster.Topology` module is a hashing and connected-node helper. It is not `Jido.Topology`, and its standby selection does not create a running replica.

## Placement provider proposal

Issue #19 suggests `place/3`, `status/1`, and `release/1`. Keep these signatures provisional. Before selecting them, decide operation identity, idempotent status reconciliation, readiness, cancellation, partial boot cleanup, and release acknowledgement.

Requirements can later include release compatibility, region, memory, tenant isolation, affinity, and cost. Unsupported requirements must fail explicitly. Static providers must not silently ignore requirements meant for dynamic hosts.

Use portable definitions and values for distributed requests. Do not make arbitrary closures a durable API. Keep credentials in provider supervision and configuration.

## Movement and recovery

A proposed fenced move has these stages:

1. Reserve compatible target capacity and record the operation.
2. Stop new work on the source; settle or mark pending requests uncertain.
3. Retain the final committed checkpoint when the source can cooperate.
4. Acquire a newer authority epoch and make lower epochs invalid at protected writes.
5. Activate and restore on the target; wait for readiness.
6. Publish the new location revision.
7. Release the old placement and unused reservations.

A lost source cannot be assumed to have completed stage 3. Recovery must use the last authoritative checkpoint. Each stage needs an explicit failure and restart path. A timeout must remain uncertain until status or authority resolves it. Never retry a Signal automatically merely because an RPC timed out.

Rebalance should use the same movement protocol with rate limits, cooldown, and spare recovery capacity. Local OTP restart and cluster replacement must not create competing activations.

## Delivery and observation

Preserve core call and cast meanings. A successful call returns a committed Agent. A successful cast acknowledges enqueue, not a saved checkpoint. Do not claim exactly-once delivery or business effects.

Cluster lifecycle Signals can feed normal control Agents and Plugins. Use bounded best-effort event delivery and telemetry. Event delivery failure must not alter placement or authority outcomes. Status should expose desired placement, observed location, authority state, operation progress, and indeterminate results separately.

## Proof order

| Step | Required evidence before promotion |
| --- | --- |
| 1. Preserve the foundation | Existing unit, peer, and example suites stay green; documented limits remain explicit |
| 2. Align with core | Prove Ref identity parity and exact Topology placement without two repair owners; prove remote resource-locality rejection |
| 3. Design authority | Select a service and enforcement point; reject an old writer after promotion, restart, asymmetric partition, and delayed disconnect |
| 4. Extract static placement | Prove provider lifecycle, operation reconciliation, readiness, and cleanup on partial failure |
| 5. Bound recovery | Prove admission, backoff, concurrency limits, and capacity release after a node failure |
| 6. Test dynamic hosts | Prove the same contracts with a local provider before a real deployment; inject Agent, host, owner-process, and parent-node loss separately |
| 7. Add policy | Prove drain and rebalance failure stages, compatibility checks, and operator preview |

Partition tests belong to `:peer`; runnable example test cases belong to `:example` under `test/examples/`. Keep example-only setup in `test/examples/support/` and use deterministic barriers. A cloud example is optional and does not replace local failure tests.

## Outside the first scope

Durable workflow orchestration, a new Signal transport, distributed Bus semantics, exactly-once effects, automatic application retries, live Agent replicas, global multi-region availability claims, and arbitrary external workspace management are outside the initial scope.

## Sources

- [Issue #19](https://github.com/agentjido/jido_cluster/issues/19): proposed control-plane direction and provider ideas.
- [Issue #1](https://github.com/agentjido/jido_cluster/issues/1): application scenario ideas.
- [Alignment review](alignment.md): local core and package source evidence.
- [Decision questions](questions.md): unresolved contract choices.
