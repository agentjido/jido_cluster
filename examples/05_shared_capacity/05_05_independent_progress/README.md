# 05_05 Independent progress

An interrupted drain retains its source and target claims. Work on a separate host still completes.

## Read the code

Read the [Topology and Cluster definition](topology.ex), the
[shared worker](../support/worker.ex), then the
[test](../../../test/examples/05_shared_capacity/05_05_independent_progress/independent_progress_test.exs).
The [test setup](../../../test/examples/support/shared_capacity_case.ex) starts
matching core instances and a named Cluster service. General peer setup and
checked shutdown are in [ClusterCase](../../../test/support/cluster_case.ex).

## Run

```sh
mise exec -- mix test test/examples/05_shared_capacity/05_05_independent_progress --only example --seed 0
```

Expected result: An interrupted drain retains its source and target claims. Work on a separate host still completes.

## Behavior and cleanup

A test barrier stops the operation task after the target is ready and before claim release. The drain reports uncertainty. A conflicting drain is rejected. The separate worker accepts a command and commits its count.

The test stops the Cluster instance and checks that every worker Agent supervisor
is empty. Peer shutdown is monitored. No hosted service or credentials are needed.
Movement tests use the [telemetry barrier](../../../test/support/movement_barrier.ex);
the barrier is test support and is not part of the domain Agent.

## Limits

This proves progress on a disjoint host in one connected scope. Restart recovery and separate budget partitions on one host are not covered.
The control journal is explicit `journal: :memory`. The Agent checkpoint store
is a separate replicated RAM Mnesia table.

Previous: [Transition capacity](../05_04_transition_capacity/README.md)
