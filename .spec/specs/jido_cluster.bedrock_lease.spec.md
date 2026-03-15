# Bedrock Lease Coordination

Disconnected-island coordination needs a durable contract before runtime code
can safely execute the same logical key across Erlang islands that do not share
connected-BEAM membership.

## Intent

This subject covers the typed lease backend config, lease claim shape, durable
lease record, and stale-writer fence token used by the planned
`{:bedrock_lease, ...}` coordination backend.

```spec-meta
id: jido_cluster.bedrock_lease
kind: module
status: active
summary: Typed Bedrock lease and fencing contract for disconnected-island coordination.
surface:
  - lib/jido/cluster/config.ex
  - lib/jido/cluster/lease_backend.ex
  - lib/jido/cluster/fence_token.ex
  - lib/jido/cluster/lease_claim.ex
  - lib/jido/cluster/lease.ex
  - test/jido_cluster/lease_models_test.exs
  - .spec/decisions/bedrock-lease-fencing.md
```

## Requirements

```spec-requirements
- id: jido_cluster.bedrock_lease.typed_backend
  statement: The `{:bedrock_lease, ...}` coordination backend shall normalize into a typed lease backend config with explicit repo, prefix, TTL, renew cadence, clock skew budget, and retry backoff.
  priority: must
  stability: stable

- id: jido_cluster.bedrock_lease.claim_shape
  statement: Lease acquisition requests shall be represented as typed claims that capture claimant identity, requested TTL, and renewal cadence for one `{manager, key}` pair.
  priority: must
  stability: stable

- id: jido_cluster.bedrock_lease.fence_token
  statement: Every lease acquisition shall issue a typed fence token that monotonically orders claim epochs and identifies the active holder for stale-writer rejection.
  priority: must
  stability: stable

- id: jido_cluster.bedrock_lease.lease_record
  statement: Durable lease records shall encode holder identity, issuance, expiry, cadence, and a fence token whose holder, lease id, and epoch match the lease record.
  priority: must
  stability: stable

- id: jido_cluster.bedrock_lease.renew_before_expiry
  statement: Lease and claim cadence shall require `renew_interval_ms < ttl_ms`.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: jido_cluster.bedrock_lease.typed_contract_examples
  given:
    - a lease backend config
    - a claim request
    - a fence token
    - a durable lease record
  when:
    - each value is built through its public constructor
  then:
    - the resulting data preserves cadence constraints and stale-writer fencing metadata
  covers:
    - jido_cluster.bedrock_lease.typed_backend
    - jido_cluster.bedrock_lease.claim_shape
    - jido_cluster.bedrock_lease.fence_token
    - jido_cluster.bedrock_lease.lease_record
    - jido_cluster.bedrock_lease.renew_before_expiry
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_cluster/lease_models_test.exs
  execute: true
  covers:
    - jido_cluster.bedrock_lease.typed_backend
    - jido_cluster.bedrock_lease.claim_shape
    - jido_cluster.bedrock_lease.fence_token
    - jido_cluster.bedrock_lease.lease_record
    - jido_cluster.bedrock_lease.renew_before_expiry
    - jido_cluster.bedrock_lease.typed_contract_examples
```
