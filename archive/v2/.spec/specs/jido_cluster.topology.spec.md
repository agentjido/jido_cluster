# Topology

Deterministic topology helpers decide which nodes own a clustered key and how
cluster-wide quorum and leadership are interpreted from the current view.

## Intent

This subject covers the connected-node view, leader selection, quorum checks,
and rendezvous-hash placement that `jido_cluster` uses to assign primary and
standby runtime nodes.

```spec-meta
id: jido_cluster.topology
kind: module
status: active
summary: Deterministic topology view and primary/standby placement for connected BEAM nodes.
surface:
  - lib/jido_cluster/topology.ex
  - lib/jido/cluster/topology.ex
  - test/jido_cluster/topology_test.exs
```

## Requirements

```spec-requirements
- id: jido_cluster.topology.connected_nodes_include_self
  statement: The connected cluster view shall include Node.self/0 and remain sorted deterministically.
  priority: must
  stability: stable

- id: jido_cluster.topology.leader_and_quorum_from_visible_nodes
  statement: Leader selection and quorum evaluation shall be derived only from the visible connected node set for a given topology view.
  priority: must
  stability: stable

- id: jido_cluster.topology.deterministic_primary_standby
  statement: Placement shall use rendezvous hashing to produce a deterministic primary/standby ordering for a given manager, key, and node set.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: jido_cluster.topology.quorum_view_snapshot
  given:
    - an explicit visible node list and a quorum threshold
  when:
    - a topology view is built
  then:
    - the view records the sorted nodes, leader, and quorum result for that input
  covers:
    - jido_cluster.topology.connected_nodes_include_self
    - jido_cluster.topology.leader_and_quorum_from_visible_nodes

- id: jido_cluster.topology.primary_standby_ordering
  given:
    - a fixed manager, key, and node list
  when:
    - placement and replica nodes are derived multiple times
  then:
    - the same primary and standby ordering is returned consistently
  covers:
    - jido_cluster.topology.deterministic_primary_standby
```

## Verification

```spec-verification
- kind: source_file
  target: lib/jido/cluster/topology.ex
  covers:
    - jido_cluster.topology.deterministic_primary_standby

- kind: command
  target: mix test test/jido_cluster/topology_test.exs
  execute: true
  covers:
    - jido_cluster.topology.connected_nodes_include_self
    - jido_cluster.topology.leader_and_quorum_from_visible_nodes
    - jido_cluster.topology.deterministic_primary_standby
    - jido_cluster.topology.quorum_view_snapshot
    - jido_cluster.topology.primary_standby_ordering
```
