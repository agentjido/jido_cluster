# 02_02 Label extension

A static cluster_worker declaration requests compute capacity. Runtime policy selects the matching host.

## Read the code

1. [Topology definition](topology.ex).
2. [Executable demo](demo.exs).
3. [Counter](../support/counter.ex) and [exact-node definition builder](../support/definition.ex).
4. [Local host setup](../support/local_nodes.ex).
5. [Public API test](../../../test/examples/02_topologies/02_02_label_extension/label_extension_test.exs) and [shared test setup](../../../test/support/topology_case.ex).

## Run

Run from `jido_cluster` with the sibling V3 dependencies. No credentials are needed.

```sh
mise exec -- mix run examples/02_topologies/02_02_label_extension/demo.exs
mise exec -- mix test test/examples/02_topologies/02_02_label_extension --only example --seed 0
```

Expected demo fields: `required_labels: ["compute"], worker_remote: true, count: 1` and `nodes_stopped: true`.

## Behavior and cleanup

The Spark extension implements `Jido.Topology.Extension`. It adds ordinary Agents and stores requirements under `jido.cluster.requirements` metadata. It does not contact hosts or select nodes during lowering. The source definition stays unchanged. Empty labels fail before activation; missing capacity fails at selection.

Each demo creates isolated loopback nodes with a unique cookie and a replicated RAM table. Recursive `after` blocks stop all hosts even after a failure. The tests assert Agent cleanup, and the shared peer case checks that controllers exit. RAM state disappears after all hosts stop.

## Limits

Requirements apply to root singleton Agents in this lesson. Group, included-scope, and capacity-provider contracts remain open.

Use the [placement selector](../../../lib/jido/cluster/placement.ex) and the [core boundary review](../../../docs/design/01_package-purpose/alignment.md) to understand package ownership.

Return to [02 Topologies](../README.md).

Previous: [Eligible node](../02_01_eligible_node/README.md).

Next: [Stateful move](../02_03_stateful_move/README.md).

The [cluster extension](../../../lib/jido/cluster/topology/extension.ex) owns static authoring. The [unit tests](../../../test/jido_cluster/topology/extension_test.exs) check lowering and core Codec parity.
