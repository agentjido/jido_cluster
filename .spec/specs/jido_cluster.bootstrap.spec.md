# Bootstrap

Bootstrap surfaces define how the package exposes its namespaces, starts its
manager supervisor, and optionally wires node discovery services.

## Intent

This subject covers the root namespace modules, the application bootstrap path,
optional cluster formation integration, and the getting-started guide.

```spec-meta
id: jido_cluster.bootstrap
kind: module
status: active
summary: Namespace, application boot, and cluster formation surfaces for jido_cluster.
surface:
  - lib/jido_cluster.ex
  - lib/jido_cluster/application.ex
  - lib/jido/cluster.ex
  - lib/jido/cluster/cluster_formation.ex
  - lib/jido_cluster/cluster_formation.ex
  - guides/getting-started.md
  - test/test_helper.exs
  - test/jido_cluster_test.exs
  - test/jido_cluster/distributed/peer_smoke_test.exs
```

## Requirements

```spec-requirements
- id: jido_cluster.bootstrap.namespaces_expose_connected_nodes
  statement: Both the legacy JidoCluster namespace and the preferred Jido.Cluster namespace shall expose connected_nodes/0 for the visible cluster view.
  priority: must
  stability: stable

- id: jido_cluster.bootstrap.application_starts_manager_supervisor
  statement: The application shall start a dynamic supervisor that hosts manager instances started at runtime.
  priority: must
  stability: stable

- id: jido_cluster.bootstrap.optional_cluster_formation_backends
  statement: Optional cluster formation shall support libcluster topologies and dns_cluster discovery when those dependencies are available.
  priority: must
  stability: evolving

- id: jido_cluster.bootstrap.getting_started_guide
  statement: The getting-started guide shall show the dependency, minimal manager setup, keyed routing, and storage-selection guidance for connected-node usage.
  priority: must
  stability: stable

- id: jido_cluster.bootstrap.peer_connected_nodes_runtime
  statement: Raw peer-started Erlang nodes shall be able to connect and execute the package topology helpers once the project code path is loaded.
  priority: must
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: jido_cluster.bootstrap.peer_smoke_cluster_connectivity
  given:
    - two raw :peer nodes with the project code path loaded
  when:
    - one node connects to the other and calls the topology helper
  then:
    - both nodes appear in the connected cluster view
  covers:
    - jido_cluster.bootstrap.namespaces_expose_connected_nodes
    - jido_cluster.bootstrap.peer_connected_nodes_runtime
```

## Verification

```spec-verification
- kind: source_file
  target: lib/jido_cluster.ex
  covers:
    - jido_cluster.bootstrap.namespaces_expose_connected_nodes

- kind: source_file
  target: lib/jido/cluster.ex
  covers:
    - jido_cluster.bootstrap.namespaces_expose_connected_nodes

- kind: source_file
  target: lib/jido_cluster/application.ex
  covers:
    - jido_cluster.bootstrap.application_starts_manager_supervisor

- kind: source_file
  target: lib/jido/cluster/cluster_formation.ex
  covers:
    - jido_cluster.bootstrap.optional_cluster_formation_backends

- kind: source_file
  target: lib/jido_cluster/cluster_formation.ex
  covers:
    - jido_cluster.bootstrap.optional_cluster_formation_backends

- kind: guide_file
  target: guides/getting-started.md
  covers:
    - jido_cluster.bootstrap.getting_started_guide

- kind: command
  target: mix test test/jido_cluster_test.exs test/jido_cluster/distributed/peer_smoke_test.exs
  execute: true
  covers:
    - jido_cluster.bootstrap.namespaces_expose_connected_nodes
    - jido_cluster.bootstrap.peer_connected_nodes_runtime
    - jido_cluster.bootstrap.peer_smoke_cluster_connectivity
```
