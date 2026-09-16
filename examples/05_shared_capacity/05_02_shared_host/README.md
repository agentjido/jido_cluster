# 05_02 Shared host

Two deployments share one host. Stopping the first leaves the second Agent and its claim active.

## Read the code

Read the [Topology and Cluster definition](topology.ex), the
[shared worker](../support/worker.ex), then the
[test](../../../test/examples/05_shared_capacity/05_02_shared_host/shared_host_test.exs).
The [test setup](../../../test/examples/support/shared_capacity_case.ex) starts
matching core instances and a named Cluster service. General peer setup and
checked shutdown are in [ClusterCase](../../../test/support/cluster_case.ex).

## Run

```sh
mise exec -- mix test test/examples/05_shared_capacity/05_02_shared_host --only example --seed 0
```

Expected result: Two deployments share one host. Stopping the first leaves the second Agent and its claim active.

## Behavior and cleanup

The test calls the second worker before and after the first stops. Its PID stays the same and its committed count reaches two.

The test stops the Cluster instance and checks that every worker Agent supervisor
is empty. Peer shutdown is monitored. No hosted service or credentials are needed.
Movement tests use the [telemetry barrier](../../../test/support/movement_barrier.ex);
the barrier is test support and is not part of the domain Agent.

## Limits

The budget counts managed Agent slots. It does not measure CPU, memory, or unmanaged work.
The control journal is explicit `journal: :memory`. The Agent checkpoint store
is a separate replicated RAM Mnesia table.

Previous: [Last slot](../05_01_last_slot/README.md) | Next: [Shared drain](../05_03_shared_drain/README.md)
