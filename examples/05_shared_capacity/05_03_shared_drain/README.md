# 05_03 Shared drain

A host drain moves both deployments and preserves their Refs and committed counts.

## Read the code

Read the [Topology and Cluster definition](topology.ex), the
[shared worker](../support/worker.ex), then the
[test](../../../test/examples/05_shared_capacity/05_03_shared_drain/shared_drain_test.exs).
The [test setup](../../../test/examples/support/shared_capacity_case.ex) starts
matching core instances and a named Cluster service. General peer setup and
checked shutdown are in [ClusterCase](../../../test/support/cluster_case.ex).

## Run

```sh
mise exec -- mix test test/examples/05_shared_capacity/05_03_shared_drain --only example --seed 0
```

Expected result: A host drain moves both deployments and preserves their Refs and committed counts.

## Behavior and cleanup

The complete target plan is reserved before movement. A test barrier observes target readiness before claim release. A new deployment is rejected while all slots are held. Drain exclusion remains until an explicit enable request.

The test stops the Cluster instance and checks that every worker Agent supervisor
is empty. Peer shutdown is monitored. No hosted service or credentials are needed.
Movement tests use the [telemetry barrier](../../../test/support/movement_barrier.ex);
the barrier is test support and is not part of the domain Agent.

## Limits

This test uses connected hosts and replicated RAM Agent storage. It does not prove durable control recovery.
The control journal is explicit `journal: :memory`. The Agent checkpoint store
is a separate replicated RAM Mnesia table.

Previous: [Shared host](../05_02_shared_host/README.md) | Next: [Transition capacity](../05_04_transition_capacity/README.md)
