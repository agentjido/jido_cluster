# Jido Cluster Usage Rules

`jido_cluster` provides distributed keyed ownership for Jido agents.

## Core Rules

- Route keyed operations through `JidoCluster.InstanceManager`.
- Do not call local `Jido.Agent.InstanceManager` directly when global singleton behavior is required.
- Use a shared backend (Mnesia, Bedrock, Postgres) for cross-node recovery/migration.
- Treat ETS as local-only storage (`shared_backend? == false`).

## Placement and Rebalance

- Ownership is deterministic via rendezvous hashing.
- Rebalancing is conservative by default (`30_000ms`, max `1` migration/tick).
- Only the deterministic leader performs migrations.

## Operational Safety

- Ensure nodes are connected before relying on cluster ownership decisions.
- For failover semantics, avoid ETS in production clusters.
- Validate adapter options at startup (`repo`, table names, prefixes, etc.).

## Testing Guidance

- Test singleton races across nodes.
- Test cross-node `call/cast` behavior.
- Test ownership changes on node join/leave.
- Assert `expected_rev` conflicts for shared storage adapters.
