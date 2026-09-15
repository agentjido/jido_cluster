# 03_07 Restore accepted placement

A worker moves, then its Scheduler restarts. Status and slot usage follow the core Controller's saved placement.

## Learn and read

Read the [Topology](restart.ex), [shared worker](../support/worker.ex), then the [tests](../../../test/examples/03_placement/03_07_restart/restart_test.exs). Setup uses the [placement case](../../../test/examples/support/placement_case.ex) and [node case](../../../test/support/cluster_case.ex).

The [operation module](../../../lib/jido/cluster/scheduler/operation.ex) reads effective placement through `Jido.Topology.Controller.agent_node/3`. Eligible accepted placements are retained before it requests further moves. A successful operation reports the accepted nodes after core readiness.

## Run

```sh
mise exec -- mix test test/examples/03_placement/03_07_restart --only example --seed 0
```

Expected result: after drain and Scheduler restart, the worker remains on the target node. Its Ref, count 1, and revision 1 survive. `placements`, `desired`, and `reservations` agree with the running worker. A second test kills the owned core Controller. The ownership process waits for core cleanup and child process exit, starts one replacement, and the Scheduler observes the new Controller PID before returning to `:ready`.

## Behavior and limits

Restart uses the same Topology ID, input, and original host inventory. Core owns its target record and checkpoint format. The cluster package does not decode or change those records. The original selected definition must remain compatible with core's accepted target; changing the initial inventory at restart is not covered.

Scheduler drain requests and operation state are temporary. Restart retains an eligible saved placement but does not restore a durable drain intent. Controller exit during an operation can leave an uncertain result that needs explicit reconciliation. These tests cover completed drain and idle Controller exit. They do not prove interrupted multi-worker drain, partition fencing, or persistence-service recovery.

Stop checks worker cleanup. Peer cleanup uses monitors. Replicated RAM data disappears when the last host stops.

Previous: [Coordinator ownership](../03_06_coordinator/README.md). Return to [03 Placement](../README.md).
