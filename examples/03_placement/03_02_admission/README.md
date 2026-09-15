# 03_02 Complete admission

Two workers need admitted slots before the Topology starts. An insufficient inventory produces a blocked result without partial startup.

## Learn and read

Read the [Topology](admission.ex), [shared worker](../support/worker.ex), then the [test](../../../test/examples/03_placement/03_02_admission/admission_test.exs). Shared setup is in the [placement case](../../../test/examples/support/placement_case.ex) and [node case](../../../test/support/cluster_case.ex).

The [planner](../../../lib/jido/cluster/scheduler/planner.ex) selects every slot before the [Scheduler](../../../lib/jido/cluster/scheduler.ex) requests activation. Existing compatible placement is retained when inventory changes.

## Run

```sh
mise exec -- mix test test/examples/03_placement/03_02_admission --only example --seed 0
```

Expected result: no workers start when compute capacity is missing. `update_hosts/2` supplies two compatible hosts with one slot each. The runtime admits and starts both workers on separate hosts, then reports readiness and one reserved slot on each host.

## Behavior and limits

Cleanup stops both workers before their peer hosts exit. The replicated RAM table is temporary. Planning failure reserves no partial slots. An activation timeout is a different result: it can be uncertain, and its planned slots remain visible until reconciliation or cleanup.

The budget belongs to one Scheduler. Separate Schedulers do not share reservations. Selection is deterministic and greedy; it does not prove optimal packing. There is no durable reservation store or global admission service.

Previous: [Requirements](../03_01_requirements/README.md). Next: [Drain](../03_03_drain/README.md).
