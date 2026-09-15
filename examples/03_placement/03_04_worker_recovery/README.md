# 03_04 Recover a worker

A worker exits while its host stays connected. The Scheduler requests a bounded repair pass from the manual core Controller.

## Learn and read

Read the [Topology](recovery.ex), [shared worker](../support/worker.ex), then the [test](../../../test/examples/03_placement/03_04_worker_recovery/recovery_test.exs). Shared setup is in the [placement case](../../../test/examples/support/placement_case.ex) and [node case](../../../test/support/cluster_case.ex).

The [Scheduler](../../../lib/jido/cluster/scheduler.ex) is the repair owner. Core remains the activation owner. Core automatic repair is disabled for the owned Controller, so two independent repair loops do not compete.

## Run

```sh
mise exec -- mix test test/examples/03_placement/03_04_worker_recovery --only example --seed 0
```

Expected result: a worker commits count 1 at revision 1, then stops. Without a test repair request, a new worker starts on the same host. The same Ref resolves to it and its checkpoint remains count 1 at revision 1. Public Scheduler status records the repair.

## Behavior and limits

Each detected worker exit starts one bounded core operation. An uncertain result pauses further work until an explicit request. There is no Signal replay. Cleanup stops the replacement worker, waits for ownership cleanup, and checks peer exit.

The test uses a stopped Agent process and replicated RAM storage. It does not prove recovery after host loss, operation-owner restart, or persistence-service loss. Core already supplies repair mechanics; this example proves their ownership within the cluster lifecycle.

Previous: [Drain](../03_03_drain/README.md). Next: [Host loss](../03_05_host_loss/README.md).
