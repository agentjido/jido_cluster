# 03 Maintained placement

These examples use `Jido.Cluster.Scheduler` to consume declared requirements and maintain placement. Tests submit inventory and operations. The runtime selects nodes, admits slots, and requests core activation or repair.

| Order | Example | Proof |
| --- | --- | --- |
| 03_01 | [Requirements](03_01_requirements/README.md) | Select a compatible connected host without patching the definition in the test |
| 03_02 | [Admission](03_02_admission/README.md) | Admit all workers before startup; add capacity through an inventory update |
| 03_03 | [Drain](03_03_drain/README.md) | Move a worker from a live node and retain its Ref and checkpoint |
| 03_04 | [Worker recovery](03_04_worker_recovery/README.md) | Request core repair after worker exit, with one repair owner |
| 03_05 | [Host loss](03_05_host_loss/README.md) | Report an unreachable source as uncertain without starting a replacement writer |
| 03_06 | [Coordinator ownership](03_06_coordinator/README.md) | Admit one connected coordinator and clean up after it exits |
| 03_07 | [Placement restart](03_07_restart/README.md) | Adopt saved placement and observe a replacement core Controller |

Run from `jido_cluster`:

```sh
mise exec -- mix test test/examples/03_placement --only example --seed 0
```

All tests use only `:example`. Each case starts isolated loopback nodes and a replicated RAM persistence table. Cleanup stops owned workers and checks that peer controllers exit. RAM data disappears when the last host stops.

The [shared worker](support/worker.ex) is example source. The [placement test case](../../test/examples/support/placement_case.ex) and [node case](../../test/support/cluster_case.ex) are test fixtures. See the [Scheduler guide](../../guides/placement.md) for the current contract.

Capacity is scoped to one Scheduler. Inventory is application configuration filtered by connected membership. This is not global admission, a dynamic host provider, or protected-write authority. Groups and includes are unsupported. Host loss is different from worker exit: an unreachable source stays uncertain.

Coordinator ownership covers connected nodes. A supervised owner retains the claim until cleanup settles. Accepted core placements survive restart through shared persistence. Drain intent and operation state do not survive Scheduler restart.

Cold-target restore requires the sibling core fix described in [the local core requirement](../02_topologies/README.md#local-core-requirement).

Previous group: [Core Topology integration](../02_topologies/README.md). Return to the [catalog](../README.md).
