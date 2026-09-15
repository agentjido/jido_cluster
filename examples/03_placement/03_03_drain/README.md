# 03_03 Drain a connected node

An operator drains a live node. The Scheduler selects another compatible host and uses the core move operation to retain committed work.

## Learn and read

Read the [Topology](drain.ex), [shared worker](../support/worker.ex), then the [test](../../../test/examples/03_placement/03_03_drain/drain_test.exs). Shared setup is in the [placement case](../../../test/examples/support/placement_case.ex) and [node case](../../../test/support/cluster_case.ex).

The [Scheduler](../../../lib/jido/cluster/scheduler.ex) admits the target before any move. Its [operation module](../../../lib/jido/cluster/scheduler/operation.ex) serializes core placement calls and waits for readiness.

## Run

```sh
mise exec -- mix test test/examples/03_placement/03_03_drain --only example --seed 0
```

Expected result: a worker commits count 1 at revision 1. Drain moves it to the other host, the same Ref resolves to the new worker, the checkpoint and revision remain unchanged, and the old process stops. The source host remains connected. The draining node becomes drained only after readiness. Draining the final eligible host is rejected without moving the worker.

## Behavior and limits

The drained host is excluded from later admission by this Scheduler. Current and desired slots remain visible during movement. Cleanup stops the final worker and waits for core ownership cleanup; peer cleanup uses monitors.

Target capacity must cover current and desired claims during the transition. Packed swaps without spare slots are rejected before movement.

This is a cooperative connected-node move using replicated RAM persistence. It does not prove uninterrupted calls, request deduplication, partition fencing, or a drain across all Schedulers on a host. Drain does not stop the Erlang node itself.

Previous: [Admission](../03_02_admission/README.md). Next: [Worker recovery](../03_04_worker_recovery/README.md).
