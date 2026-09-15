# Decisions to make

Status: open. Recommendations below are proposed, not accepted contracts.

## D01: First supported deployment

Recommendation: fixed connected BEAM nodes first. Preserve the current foundation as an explicit mode. Add dynamic providers only after static placement lifecycle tests exist.

Alternative: implement FLAME and static nodes together. This can test provider generality earlier, but adds host boot and release faults before the ownership model is settled.

Proof gate: routing, readiness, partial-start cleanup, owner loss, and uncertain placement must have local node tests.

## D02: Identity and API

Recommendation: use core `Jido.Agent.Ref` as canonical logical identity. Keep manager/key convenience calls with an explicit mapping and compatibility plan.

Open: does a manager host one Agent module, several modules, or a declared Topology? Where are the module and definition version recorded if they are not part of the Ref?

Proof gate: same Ref on different nodes resolves to the same persistence identity; old keys do not lose saved state after adoption.

## D03: Lifecycle ownership

Recommendation: retain one core Controller for each declared Topology. The cluster layer selects placement and submits exact-node operations. Independently keyed Agents use a separate cluster placement owner through public Jido lifecycle APIs.

Open: which layer requests replacement after loss? What happens when a Controller repairs a target while the cluster coordinator is moving it? Does loss of the Controller require a separate topology-owner authority grant?

Proof gate: concurrent repair and move cannot start competing ready activations. An uncertain move remains visible until it is reconciled.

## D04: Authority enforcement

Recommendation: select one authority service and one atomic enforcement point before a partition-safe release claim. Keep placement lifecycle ownership separate from write authority.

Open: can a storage adapter enforce authority metadata atomically with current core CAS without a core API change? How is a holder bound to one activation? How are tombstones, maintenance writes, and deletes protected? What can run while authority is unavailable?

Proof gate: an old activation cannot commit after a newer holder is granted authority. Test delayed disconnect, asymmetric partition, two recovering islands, authority-service loss, and restart. A CAS conflict alone does not satisfy this gate.

External effects need a separate capability contract. Checkpoint fencing must not be presented as exactly-once tools or payments.

## D05: Provider contract

Recommendation: separate placement policy from host mechanics. Implement a static provider before a dynamic provider. Keep issue #19's `place/3`, `status/1`, and `release/1` provisional.

Open: does a provider place an AgentServer, a Jido host supervisor, or a small Agent group? Who holds its long-lived process link? How does a request ID reconcile a timed-out start? When does release become complete? Can a provider report capacity without acquiring it?

Proof gate: kill the Agent, host, placement owner, and requesting process separately; prove cleanup and status reconciliation after every loss.

## D06: FLAME and external workspaces

Recommendation: FLAME is an optional dynamic BEAM placement candidate. A Sprite used only for files or tool execution stays an application resource until a common resource contract is justified.

Open: should external workspaces enter `jido_cluster` at all? Should one dynamic host run one Agent, a group, or many unrelated Agents? Which release and node-local services must be present on the host?

Proof gate: verify the selected provider's current documented lifecycle, then prove the same static-provider contracts locally. A connected external runtime host also needs sleep/wake, network, restart, and compatibility evidence.

No provider dependency is added by this design change.

## D07: Policy, delivery, and operators

Recommendation: built-in policy should be small and deterministic. Application quotas, cost decisions, and domain retries can use normal control Agents or Plugins. The runtime must still enforce authority and capacity limits.

Open: which drain, stop, move, and preview operations are required first? Which operation states are durable? When can a caller retry a rejected request, and how is an unknown outcome resolved?

Proof gate: bounded recovery concurrency, queue limits, backoff, release of reservations, stale-location handling, and visible indeterminate outcomes. Event delivery failure must not change the operation result.

## First design slice

Resolve D01 through D04 first. Then write a static placement protocol with request identity, state transitions, failure handling, and authority enforcement. Add contract tests before implementing dynamic capacity. Use [core alignment](alignment.md) to identify any required core change and keep that change scoped to its owner repository.

When a decision is accepted, add its date, reason, rejected alternatives, affected packages, and evidence links here. Update [the proposed design](design.md) and the implementation alignment in the same change.
