# 03_06 Own one connected coordinator

Two control nodes request the same Topology. One coordinator is accepted. If it exits, owned workers stop before another coordinator can start.

## Learn and read

Read the [Topology](coordinator.ex), [shared worker](../support/worker.ex), then the [tests](../../../test/examples/03_placement/03_06_coordinator/coordinator_test.exs). Setup uses the [placement case](../../../test/examples/support/placement_case.ex) and [node case](../../../test/support/cluster_case.ex).

The [Scheduler](../../../lib/jido/cluster/scheduler.ex) uses a supervised [ownership process](../../../lib/jido/cluster/scheduler/owner.ex). That process holds the connected global name, monitors the Scheduler, and owns its operation tasks and core Controller. Cleanup does not depend on the Scheduler's termination callback.

## Run

```sh
mise exec -- mix test test/examples/03_placement/03_06_coordinator --only example --seed 0
```

Expected result: concurrent starts on two connected nodes produce one accepted Scheduler and one `{:scheduler_already_running, owner}` rejection. The losing node has no core Controller. A second test kills a ready Scheduler, checks Controller and worker cleanup, then starts a coordinator on the other control node. The worker restores count 1 at revision 1.

## Behavior and limits

Ownership is scoped by Jido namespace and Topology ID. Name-table synchronization precedes the claim. The claim remains held while cleanup runs. Normal stop reports failed or uncertain cleanup and keeps the ownership process alive. Another coordinator must not bypass that claim.

This proves competition and process exit within a connected cluster. It does not prove partition safety, control-host replacement, persistent authority, or cancellation during an active business call. Coordinator replacement is an explicit application request. Replicated RAM storage must retain a live host to preserve the checkpoint.

Previous: [Host loss](../03_05_host_loss/README.md). Next: [Placement restart](../03_07_restart/README.md).
