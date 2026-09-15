# 03_01 Requirements to placement

A declaration requests compute capacity. The Scheduler selects a connected host that satisfies that requirement and starts the worker through core.

## Learn and read

Read the [Topology](scheduling.ex), [shared worker](../support/worker.ex), then the [tests](../../../test/examples/03_placement/03_01_requirements/requirements_test.exs). The [test case](../../../test/examples/support/placement_case.ex) creates matching named Jido instances. General node setup is in [ClusterCase](../../../test/support/cluster_case.ex).

The [extension](../../../lib/jido/cluster/topology/extension.ex) supplies static requirements. The [Scheduler](../../../lib/jido/cluster/scheduler.ex) consumes them at runtime. The test does not select a node or modify the definition.

## Run

```sh
mise exec -- mix test test/examples/03_placement/03_01_requirements --only example --seed 0
```

Expected result: the worker starts on the compute host, one command commits count 1, and the source definition stays unchanged. A second case changes the remote namespace; the runtime rejects that host before activation and releases its planned slots.

## Behavior and limits

Stopping the Scheduler waits for the core ownership cleanup event. The test checks worker exit; peer cleanup uses monitors. These tests use replicated RAM storage and need no credentials.

Inventory is configured by the application. Connected membership and namespace parity are checked. This does not verify release hashes, disk capacity, or arbitrary node-local resources. Only root singleton Agents are supported.

Previous: [Bus locality](../../02_topologies/02_05_bus_locality/README.md). Next: [Admission](../03_02_admission/README.md).
