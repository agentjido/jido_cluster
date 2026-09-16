# 05_01 Last slot

Two independent peer callers request the final slot. One deployment starts. The other request returns a capacity error.

## Read the code

Read the [Topology and Cluster definition](topology.ex), the
[shared worker](../support/worker.ex), then the
[test](../../../test/examples/05_shared_capacity/05_01_last_slot/last_slot_test.exs).
The [test setup](../../../test/examples/support/shared_capacity_case.ex) starts
matching core instances and a named Cluster service. General peer setup and
checked shutdown are in [ClusterCase](../../../test/support/cluster_case.ex).

## Run

```sh
mise exec -- mix test test/examples/05_shared_capacity/05_01_last_slot --only example --seed 0
```

Expected result: Two independent peer callers request the final slot. One deployment starts. The other request returns a capacity error.

## Behavior and cleanup

The test releases two caller tasks together through separate peer channels. It checks the accepted claim, the rejected deployment status, the actual Agent count, and a committed command.

The test stops the Cluster instance and checks that every worker Agent supervisor
is empty. Peer shutdown is monitored. No hosted service or credentials are needed.
Movement tests use the [telemetry barrier](../../../test/support/movement_barrier.ex);
the barrier is test support and is not part of the domain Agent.

## Limits

This test does not establish fairness or admission across disconnected owners.
The control journal is explicit `journal: :memory`. The Agent checkpoint store
is a separate replicated RAM Mnesia table.

Previous: [Request identity](../../04_deployment/04_03_request_identity/README.md) | Next: [Shared host](../05_02_shared_host/README.md)
