# 02_01 Eligible node

A local control Agent and a remote worker start from one core Topology.

## Read the code

1. [Topology definition](topology.ex).
2. [Executable demo](demo.exs).
3. [Counter](../support/counter.ex) and [exact-node definition builder](../support/definition.ex).
4. [Local host setup](../support/local_nodes.ex).
5. [Public API test](../../../test/examples/02_topologies/02_01_eligible_node/eligible_node_test.exs) and [shared test setup](../../../test/support/topology_case.ex).

## Run

Run from `jido_cluster` with the sibling V3 dependencies. No credentials are needed.

```sh
mise exec -- mix run examples/02_topologies/02_01_eligible_node/demo.exs
mise exec -- mix test test/examples/02_topologies/02_01_eligible_node --only example --seed 0
```

Expected demo fields: `control_local: true, worker_remote: true, count: 1` and `nodes_stopped: true`.

## Behavior and cleanup

Selection excludes a host marked unavailable. No eligible host returns `:no_eligible_node`. Core owns readiness and activation.

Each demo creates isolated loopback nodes with a unique cookie and a replicated RAM table. Recursive `after` blocks stop all hosts even after a failure. The tests assert Agent cleanup, and the shared peer case checks that controllers exit. RAM state disappears after all hosts stop.

## Limits

No automatic discovery, admission queue, or durable authority is provided.

Use the [placement selector](../../../lib/jido/cluster/placement.ex) and the [core boundary review](../../../docs/design/01_package-purpose/alignment.md) to understand package ownership.

Return to [02 Topologies](../README.md).

Next: [Label extension](../02_02_label_extension/README.md).
