# 02_03 Stateful move

A counter moves to a selected node and retains its core Ref and committed checkpoint.

## Read the code

1. [Topology definition](topology.ex) and [shared counter](../support/counter.ex).
2. [Runnable test case](../../../test/examples/02_topologies/02_03_stateful_move/stateful_move_test.exs).
3. [Test definition builder](../../../test/examples/support/definition.ex) and [Topology setup](../../../test/examples/support/topology_case.ex).
4. [General node setup](../../../test/support/cluster_case.ex).

## Run

Run from `jido_cluster` with the sibling V3 dependencies. No credentials are needed.

```sh
mise exec -- mix test test/examples/02_topologies/02_03_stateful_move --only example --seed 0
```

Expected assertions: The same Ref resolves to a new worker after the old worker stops. The saved count is 2 at revision 2. The next command commits count 3 at revision 3.

## Behavior and cleanup

The source commits count 2 at revision 2. `Controller.place_agent/4` stops the old activation and starts a repair pass. After readiness, the target resolves the same Ref, restores revision 2, and commits count 3 at revision 3.

Each test creates isolated loopback nodes with a unique cookie and a replicated RAM table. Node cleanup is registered before remote setup can fail. The test checks Agent cleanup, and the shared peer case uses monitors to check that peer controllers exit. RAM state disappears after all hosts stop.

## Limits

This is a cooperative connected-node move. It does not supply a new handoff protocol, request deduplication, or partition fencing.

Use the [placement selector](../../../lib/jido/cluster/placement.ex) and the [core boundary review](../../../docs/design/01_package-purpose/alignment.md) to understand package ownership.

Return to [02 Topologies](../README.md).

Previous: [Label extension](../02_02_label_extension/README.md).

Next: [Host recovery](../02_04_host_recovery/README.md).
