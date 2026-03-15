---
id: bedrock-lease-fencing
date: 2026-03-15
status: accepted
affects:
  - jido_cluster.bedrock_lease
---

# ADR: Bedrock Lease And Fencing Contract

## Context

Connected-BEAM ownership in `jido_cluster` relies on node visibility and
manager-routed placement. That is not enough for disconnected Erlang islands,
where two runtimes may be unable to communicate directly but can still reach the
same durable substrate.

The disconnected-island roadmap needs a coordination contract that:

- works without BEAM node membership
- gives one logical owner for one `{manager, key}` pair
- prevents stale writers from continuing after their lease is superseded
- can be tested independently of the full runtime

## Decision

We standardize the disconnected-island coordination contract around four typed
models:

1. `Jido.Cluster.LeaseBackend`
   - normalized `{:bedrock_lease, ...}` config
   - explicit `repo`, `prefix`, `ttl_ms`, `renew_interval_ms`,
     `clock_skew_ms`, and `retry_backoff_ms`

2. `Jido.Cluster.LeaseClaim`
   - one acquisition or renewal request for a `{manager, key}` pair
   - includes claimant identity plus requested TTL and renew cadence

3. `Jido.Cluster.FenceToken`
   - monotonically ordered token issued on successful acquisition
   - includes `epoch`, `lease_id`, `holder`, and `issued_at_ms`

4. `Jido.Cluster.Lease`
   - durable lease record stored in Bedrock
   - includes holder identity, issuance, expiry, cadence, and the active fence

## Contract Rules

- One durable lease record exists per `{manager, key}`.
- Every successful acquisition creates a new `lease_id` and a new fence token.
- `epoch` is the stale-writer boundary. Higher epoch wins.
- Writers must carry the current fence token when they attempt durable actions.
- Renewals are only valid when the caller still holds the current lease id and
  fence token.
- `renew_interval_ms` must always be less than `ttl_ms`.
- Expired or explicitly released leases may be claimed by another island.
- On heal, islands do not reconcile by pid or node visibility; they reconcile by
  lease freshness and fence epoch.

## Consequences

- Disconnected-island runtime code can be implemented against typed contracts
  instead of option maps.
- `Jido.Cluster.Config` now normalizes `{:bedrock_lease, ...}` into a typed
  `Jido.Cluster.LeaseBackend` struct.
- The runtime implementation for disconnected islands remains a separate task.
  This ADR fixes the contract first so the implementation does not invent its
  own wire format later.
