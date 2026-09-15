# 02_02 Label extension

A static cluster_worker declaration requests compute capacity. Runtime policy selects the matching host.

## Read the code

1. [Topology definition](topology.ex) and [shared counter](../support/counter.ex).
2. [Runnable test case](../../../test/examples/02_topologies/02_02_label_extension/label_extension_test.exs).
3. [Test definition builder](../../../test/examples/support/definition.ex) and [Topology setup](../../../test/examples/support/topology_case.ex).
4. [General node setup](../../../test/support/cluster_case.ex).

## Run

Run from `jido_cluster` with the sibling V3 dependencies. No credentials are needed.

```sh
mise exec -- mix test test/examples/02_topologies/02_02_label_extension --only example --seed 0
```

Expected assertions: The definition retains its compute label requirement. Selection starts the worker on the matching remote node, where one command commits count 1. Missing capacity returns an error.

## Behavior and cleanup

The Spark extension implements `Jido.Topology.Extension`. It adds ordinary Agents and stores requirements under `jido.cluster.requirements` metadata. It does not contact hosts or select nodes during lowering. The source definition stays unchanged. Empty labels fail before activation; missing capacity fails at selection.

Each test creates isolated loopback nodes with a unique cookie and a replicated RAM table. Node cleanup is registered before remote setup can fail. The test checks Agent cleanup, and the shared peer case uses monitors to check that peer controllers exit. RAM state disappears after all hosts stop.

## Limits

Requirements apply to root singleton Agents in this lesson. Group, included-scope, and capacity-provider contracts remain open.

Use the [placement selector](../../../lib/jido/cluster/placement.ex) and the [core boundary review](../../../docs/design/01_package-purpose/alignment.md) to understand package ownership.

Return to [02 Topologies](../README.md).

Previous: [Eligible node](../02_01_eligible_node/README.md).

Next: [Stateful move](../02_03_stateful_move/README.md).

The [cluster extension](../../../lib/jido/cluster/topology/extension.ex) owns static authoring. The [unit tests](../../../test/jido_cluster/topology/extension_test.exs) check lowering and core Codec parity.
