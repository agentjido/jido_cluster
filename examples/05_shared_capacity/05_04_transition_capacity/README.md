# 05_04 Transition capacity

A drain starts no move when the target is full. The application stops a target occupant and retries the drain.

## Read the code

Read the [Topology and Cluster definition](topology.ex), the
[shared worker](../support/worker.ex), then the
[test](../../../test/examples/05_shared_capacity/05_04_transition_capacity/transition_capacity_test.exs).
The [test setup](../../../test/examples/support/shared_capacity_case.ex) starts
matching core instances and a named Cluster service. General peer setup and
checked shutdown are in [ClusterCase](../../../test/support/cluster_case.ex).

## Run

```sh
mise exec -- mix test test/examples/05_shared_capacity/05_04_transition_capacity --only example --seed 0
```

Expected result: A drain starts no move when the target is full. The application stops a target occupant and retries the drain.

## Behavior and cleanup

The first request keeps the source PID and committed state. The retry holds one source claim and one target claim at the movement barrier. It releases the source claim only after cleanup.

The test stops the Cluster instance and checks that every worker Agent supervisor
is empty. Peer shutdown is monitored. No hosted service or credentials are needed.
Movement tests use the [telemetry barrier](../../../test/support/movement_barrier.ex);
the barrier is test support and is not part of the domain Agent.

## Limits

The example adds available capacity by releasing a slot. It does not resize a live host budget or create hosts.
The control journal is explicit `journal: :memory`. The Agent checkpoint store
is a separate replicated RAM Mnesia table.

Previous: [Shared drain](../05_03_shared_drain/README.md) | Next: [Independent progress](../05_05_independent_progress/README.md)
