# 03_05 Report uncertain host loss

A source host becomes unreachable. The Scheduler reports uncertainty instead of treating spare capacity as permission to start another writer.

## Learn and read

Read the [Topology](host_loss.ex), [shared worker](../support/worker.ex), then the [three-node test](../../../test/examples/03_placement/03_05_host_loss/host_loss_test.exs). Shared setup is in the [placement case](../../../test/examples/support/placement_case.ex) and [node case](../../../test/support/cluster_case.ex).

The [Scheduler](../../../lib/jido/cluster/scheduler.ex) checks current selected sources before new placement. Inventory changes do not erase an unresolved source.

## Run

```sh
mise exec -- mix test test/examples/03_placement/03_05_host_loss --only example --seed 0
```

Expected result: the worker host exits. Status becomes `:uncertain` with `{:source_unreachable, nodes}`. Adding a compatible spare host leaves the selected source unresolved, and no worker with the same ID starts on the spare.

## Behavior and limits

The test knows that it stopped a peer. The production Scheduler sees only an unreachable node and does not receive that proof. This is intentional: a partition can produce the same local observation. Stopping the Scheduler cleans up its reachable resources and waits for the core ownership event. All peer processes are checked during cleanup.

This proves conservative behavior after confirmed test host exit. It is not an asymmetric partition test and does not provide protected-write fencing, automatic host replacement, or an authority service. The RAM checkpoint alone cannot grant a new writer authority.

Previous: [Worker recovery](../03_04_worker_recovery/README.md). Return to [03 Placement](../README.md).
