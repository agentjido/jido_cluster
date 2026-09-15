# 02 Topologies

These lessons build on core `Jido.Topology`, static `Jido.Topology.Extension` lowering, and the core Controller. Cluster policy selects a node; core owns activation and readiness.

| Order | Lesson | Main proof |
| --- | --- | --- |
| 02_01 | [Eligible node](02_01_eligible_node/README.md) | A local control Agent and a remote worker start from one core Topology. |
| 02_02 | [Label extension](02_02_label_extension/README.md) | A static cluster_worker declaration requests compute capacity. Runtime policy selects the matching host. |
| 02_03 | [Stateful move](02_03_stateful_move/README.md) | A counter moves to a selected node and retains its core Ref and committed checkpoint. |
| 02_04 | [Host recovery](02_04_host_recovery/README.md) | After a test host exits, an application replaces the core Controller and restores its worker on compatible capacity. |
| 02_05 | [Bus locality](02_05_bus_locality/README.md) | A remote move is rejected before it breaks a worker subscription to a Controller-local Bus. |

Run the complete section:

```sh
mise exec -- mix test test/examples/02_topologies --only example --seed 0
```

Each lesson also has a `mix run` demo. Read the lessons in order. Shared code is limited to a counter, definition construction, and local host setup. Tests use only `:example`, including the three-node recovery case.

Return to the [catalog](../README.md).

## Local core requirement

The restore lessons require core commit `9f4cc2b0` (`fix(topology): load definitions before checkpoint restore`) in the sibling `jido` checkout. This fix loads the Agent definition before safe checkpoint decoding on a cold host. It is a separate local core commit. CI selects the upstream core `release/v3` ref, so that ref must include the fix before the restore lessons can pass there.
