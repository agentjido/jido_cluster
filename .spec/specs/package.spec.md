# Package

Current-truth package contract for the alpha `Jido.Cluster.*` connected-BEAM runtime.

## Intent

This subject captures the high-level public surface and scope of `jido_cluster`
while the clustered ownership and failover model is still evolving.

```spec-meta
id: jido_cluster.package
kind: package
status: active
summary: Alpha connected-BEAM package surface for clustered Jido agents.
surface:
  - README.md
  - lib/jido/cluster.ex
  - lib/jido/cluster/instance_manager.ex
  - lib/jido/cluster/topology.ex
```

## Requirements

```spec-requirements
- id: jido_cluster.package.alpha_status
  statement: The package README shall state that jido_cluster is alpha-quality and not ready for production use.
  priority: must
  stability: stable

- id: jido_cluster.package.public_namespace
  statement: The preferred public namespace shall be Jido.Cluster.* while legacy JidoCluster.* modules may remain as compatibility shims.
  priority: must
  stability: stable

- id: jido_cluster.package.connected_beam_runtime
  statement: The package shall target connected-BEAM keyed agent ownership, routing, and conservative rebalancing as its primary runtime scope.
  priority: must
  stability: evolving
```

## Verification

```spec-verification
- kind: readme_file
  target: README.md
  covers:
    - jido_cluster.package.alpha_status
    - jido_cluster.package.public_namespace
    - jido_cluster.package.connected_beam_runtime

- kind: source_file
  target: lib/jido/cluster.ex
  covers:
    - jido_cluster.package.public_namespace

- kind: source_file
  target: lib/jido/cluster/instance_manager.ex
  covers:
    - jido_cluster.package.public_namespace
```
