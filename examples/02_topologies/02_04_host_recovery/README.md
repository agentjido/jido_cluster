# 02_04 Host recovery

After a test host exits, an application replaces the core Controller and restores its worker on compatible capacity.

## Read the code

1. [Topology definition](topology.ex).
2. [Executable demo](demo.exs).
3. [Counter](../support/counter.ex) and [exact-node definition builder](../support/definition.ex).
4. [Local host setup](../support/local_nodes.ex).
5. [Public API test](../../../test/examples/02_topologies/02_04_host_recovery/host_recovery_test.exs) and [shared test setup](../../../test/support/topology_case.ex).

## Run

Run from `jido_cluster` with the sibling V3 dependencies. No credentials are needed.

```sh
mise exec -- mix run examples/02_topologies/02_04_host_recovery/demo.exs
mise exec -- mix test test/examples/02_topologies/02_04_host_recovery --only example --seed 0
```

Expected demo fields: `same_ref: true, host_exit_confirmed: true, restored_count: 1, final_count: 2` and `nodes_stopped: true`.

## Behavior and cleanup

The test stops the old Erlang host and waits for its controller process to exit. Selection excludes that host. The application stops the old core Controller and starts a replacement with the same topology ID and a selected exact node. The worker keeps its Ref and restores the saved revision. The test waits for the public ownership-cleanup event before replacement.

Each demo creates isolated loopback nodes with a unique cookie and a replicated RAM table. Recursive `after` blocks stop all hosts even after a failure. The tests assert Agent cleanup, and the shared peer case checks that controllers exit. RAM state disappears after all hosts stop.

## Limits

Recovery is explicit application coordination, not an automatic cluster service. A disconnected node is not proved dead. Do not use this path for partitions without protected-write fencing. The lesson starts with a static exact-node target; migration of an already persisted placement target is outside its scope.

Use the [placement selector](../../../lib/jido/cluster/placement.ex) and the [core boundary review](../../../docs/design/01_package-purpose/alignment.md) to understand package ownership.

Return to [02 Topologies](../README.md).

Previous: [Stateful move](../02_03_stateful_move/README.md).

Next: [Bus locality](../02_05_bus_locality/README.md).
