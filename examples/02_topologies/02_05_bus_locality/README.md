# 02_05 Bus locality

A remote move is rejected before it breaks a worker subscription to a Controller-local Bus.

## Read the code

1. [Topology definition](topology.ex) and [shared counter](../support/counter.ex).
2. [Runnable test case](../../../test/examples/02_topologies/02_05_bus_locality/bus_locality_test.exs).
3. [Test definition builder](../../../test/examples/support/definition.ex) and [Topology setup](../../../test/examples/support/topology_case.ex).
4. [General node setup](../../../test/support/cluster_case.ex).

## Run

Run from `jido_cluster` with the sibling V3 dependencies. No credentials are needed.

```sh
mise exec -- mix test test/examples/02_topologies/02_05_bus_locality --only example --seed 0
```

Expected assertions: Both placement policy and core reject the remote move. The worker keeps its PID. A local Bus publication commits count 1, and cleanup stops the worker and Bus.

## Behavior and cleanup

Cluster policy checks locality before placement. Core also rejects the remote request. The worker keeps its PID, and publishing to the local Bus still increments its count. Cleanup stops the worker and Bus.

Each test creates isolated loopback nodes with a unique cookie and a replicated RAM table. Node cleanup is registered before remote setup can fail. The test checks Agent cleanup, and the shared peer case uses monitors to check that peer controllers exit. RAM state disappears after all hosts stop.

## Limits

This does not provide a distributed Bus or external transport. Remote resources need their own explicit contracts.

Use the [placement selector](../../../lib/jido/cluster/placement.ex) and the [core boundary review](../../../docs/design/01_package-purpose/alignment.md) to understand package ownership.

Return to [02 Topologies](../README.md).

Previous: [Host recovery](../02_04_host_recovery/README.md).
