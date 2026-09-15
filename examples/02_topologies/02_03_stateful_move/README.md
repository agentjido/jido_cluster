# 02_03 Stateful move

A counter moves to a selected node and retains its core Ref and committed checkpoint.

## Read the code

1. [Topology definition](topology.ex).
2. [Executable demo](demo.exs).
3. [Counter](../support/counter.ex) and [exact-node definition builder](../support/definition.ex).
4. [Local host setup](../support/local_nodes.ex).
5. [Public API test](../../../test/examples/02_topologies/02_03_stateful_move/stateful_move_test.exs) and [shared test setup](../../../test/support/topology_case.ex).

## Run

Run from `jido_cluster` with the sibling V3 dependencies. No credentials are needed.

```sh
mise exec -- mix run examples/02_topologies/02_03_stateful_move/demo.exs
mise exec -- mix test test/examples/02_topologies/02_03_stateful_move --only example --seed 0
```

Expected demo fields: `same_ref: true, old_stopped: true, restored_count: 2, final_count: 3` and `nodes_stopped: true`.

## Behavior and cleanup

The source commits count 2 at revision 2. `Controller.place_agent/4` stops the old activation and starts a repair pass. After readiness, the target resolves the same Ref, restores revision 2, and commits count 3 at revision 3.

Each demo creates isolated loopback nodes with a unique cookie and a replicated RAM table. Recursive `after` blocks stop all hosts even after a failure. The tests assert Agent cleanup, and the shared peer case checks that controllers exit. RAM state disappears after all hosts stop.

## Limits

This is a cooperative connected-node move. It does not supply a new handoff protocol, request deduplication, or partition fencing.

Use the [placement selector](../../../lib/jido/cluster/placement.ex) and the [core boundary review](../../../docs/design/01_package-purpose/alignment.md) to understand package ownership.

Return to [02 Topologies](../README.md).

Previous: [Label extension](../02_02_label_extension/README.md).

Next: [Host recovery](../02_04_host_recovery/README.md).
