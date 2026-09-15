# 02_01 Eligible node

A local control Agent and a remote worker start from one core Topology.

## Read the code

1. [Topology definition](topology.ex) and [shared counter](../support/counter.ex).
2. [Runnable test case](../../../test/examples/02_topologies/02_01_eligible_node/eligible_node_test.exs).
3. [Test definition builder](../../../test/examples/support/definition.ex) and [Topology setup](../../../test/examples/support/topology_case.ex).
4. [General node setup](../../../test/support/cluster_case.ex).

## Run

Run from `jido_cluster` with the sibling V3 dependencies. No credentials are needed.

```sh
mise exec -- mix test test/examples/02_topologies/02_01_eligible_node --only example --seed 0
```

Expected assertions: The control Agent stays local, the worker starts on the selected remote node, and one command commits count 1. No eligible node returns an error.

## Behavior and cleanup

Selection excludes a host marked unavailable. No eligible host returns `:no_eligible_node`. Core owns readiness and activation.

Each test creates isolated loopback nodes with a unique cookie and a replicated RAM table. Node cleanup is registered before remote setup can fail. The test checks Agent cleanup, and the shared peer case uses monitors to check that peer controllers exit. RAM state disappears after all hosts stop.

## Limits

No automatic discovery, admission queue, or durable authority is provided.

Use the [placement selector](../../../lib/jido/cluster/placement.ex) and the [core boundary review](../../../docs/design/01_package-purpose/alignment.md) to understand package ownership.

Return to [02 Topologies](../README.md).

Next: [Label extension](../02_02_label_extension/README.md).
