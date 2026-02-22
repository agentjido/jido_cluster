# CHANGELOG

## 0.1.0 - 2026-02-21

### Added

- Distributed `JidoCluster.InstanceManager` wrapper over `Jido.Agent.InstanceManager`.
- Deterministic key ownership with rendezvous hashing in `JidoCluster.Topology`.
- Conservative leader-only periodic rebalancer with telemetry events.
- Optional cluster formation support for `libcluster` and `dns_cluster`.
- `Jido.Storage` adapters for ETS, Mnesia, Bedrock, and Postgres (raw Ecto).
- Shared-backend capability checks for migration/failover behavior.
- Distributed test suite using `ex_unit_cluster` plus low-level `:peer` smoke tests.
- Package QA baseline: CI/release workflows, quality aliases, docs and contribution files.
