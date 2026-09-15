# 02_05 Bus locality

A remote move is rejected before it breaks a worker subscription to a Controller-local Bus.

## Read the code

1. [Topology definition](topology.ex).
2. [Executable demo](demo.exs).
3. [Counter](../support/counter.ex) and [exact-node definition builder](../support/definition.ex).
4. [Local host setup](../support/local_nodes.ex).
5. [Public API test](../../../test/examples/02_topologies/02_05_bus_locality/bus_locality_test.exs) and [shared test setup](../../../test/support/topology_case.ex).

## Run

Run from `jido_cluster` with the sibling V3 dependencies. No credentials are needed.

```sh
mise exec -- mix run examples/02_topologies/02_05_bus_locality/demo.exs
mise exec -- mix test test/examples/02_topologies/02_05_bus_locality --only example --seed 0
```

Expected demo fields: `remote_move_rejected: true, same_worker: true, bus_delivery_count: 1` and `nodes_stopped: true`.

## Behavior and cleanup

Cluster policy checks locality before placement. Core also rejects the remote request. The worker keeps its PID, and publishing to the local Bus still increments its count. Cleanup stops the worker and Bus.

Each demo creates isolated loopback nodes with a unique cookie and a replicated RAM table. Recursive `after` blocks stop all hosts even after a failure. The tests assert Agent cleanup, and the shared peer case checks that controllers exit. RAM state disappears after all hosts stop.

## Limits

This does not provide a distributed Bus or external transport. Remote resources need their own explicit contracts.

Use the [placement selector](../../../lib/jido/cluster/placement.ex) and the [core boundary review](../../../docs/design/01_package-purpose/alignment.md) to understand package ownership.

Return to [02 Topologies](../README.md).

Previous: [Host recovery](../02_04_host_recovery/README.md).
