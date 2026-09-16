# 02 Top-level API and placement targets

Current direction: [Architectural vision](../../00_architecture/README.md)
and [Delivery slices](../../00_architecture/delivery-plan.md) supersede this document's
scope and sequence where they differ. Federation is now in scope, before dynamic
providers. Fabric capabilities may be consolidated into Cluster.

Status: proposed. Written on 2026-09-15. The API examples are design sketches,
not executable examples or implemented functions.

Scope revision: [03 Package focus](../03_package-focus/README.md) recommends
shared admission and restart-safe placement on static hosts first. Its release
scope and delivery order take precedence over this broader proposal. Providers
follow those proofs; federation is deferred to a separate integration decision.

`jido_cluster` should deploy core Jido topologies onto suitable BEAM hosts,
acquire hosts when required, and coordinate placement through movement,
recovery, and release. Applications address Agents through stable core Refs.

Host intelligence supplies validated runtime and capacity observations. Optional
Signal federation lets selected events cross hosts while subscriptions follow
Agent placement. Both extend the same control plane and have separate proof gates.

The proposed first public surface is topology-first. It supports existing nodes
and a small native provider contract. A provider must produce a compatible,
connected BEAM host before core can activate topology Agents there.

## Read in order

1. [Design](design.md): purpose, API, DSL, providers, lifecycle, and test plan.
2. [Alignment](alignment.md): current source, existing evidence, and missing work.
3. [Host intelligence](host-intelligence.md): reports, freshness, compatibility,
   shared-host capacity, and policy tests.
4. [Signal federation](signal-federation.md): local mirrors, Ref bindings,
   transport, delivery limits, and movement tests.
5. [Earlier purpose design](../01_package-purpose/design.md): identity, location,
   authority, and the wider control-plane proposal.

The main recommendation is a narrow placement runtime that depends on Jido
core. AI applications can use it without making cluster placement depend on
`jido_ai`. LitterBox is useful prior art for backend mechanics; this proposal
does not select copying its code or adding its package as a dependency.

Return to the [design index](../../README.md).
