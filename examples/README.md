# Jido Cluster examples

These examples are living documentation. Each example has source code, a run command, and tests that check its stated result. The folder numbers set the reading order.

| Group | Example | Learn |
| --- | --- | --- |
| [01 Cluster](01_cluster/README.md) | [01_01 Keyed counter](01_cluster/01_01_keyed_counter/README.md) | Route commands across nodes and restore a saved counter after owner loss |
| [02 Topologies](02_topologies/README.md) | [02_01 Eligible node](02_topologies/02_01_eligible_node/README.md) | Select available capacity and activate a core Topology |
| 02 Topologies | [02_02 Label extension](02_topologies/02_02_label_extension/README.md) | Lower static requirements and apply runtime selection |
| 02 Topologies | [02_03 Stateful move](02_topologies/02_03_stateful_move/README.md) | Preserve Ref identity and commit revision during movement |
| 02 Topologies | [02_04 Host recovery](02_topologies/02_04_host_recovery/README.md) | Replace a Controller after confirmed host exit |
| 02 Topologies | [02_05 Bus locality](02_topologies/02_05_bus_locality/README.md) | Reject a remote move and retain local delivery |

Example source code compiles in `dev` and `test`. It does not compile in `prod`. Tests mirror each numbered folder under `test/examples/` and use only the `:example` tag. The normal test command excludes this tag.

Run from `jido_cluster`:

```sh
mise exec -- mix test.examples
mise exec -- mix run examples/01_cluster/01_01_keyed_counter/demo.exs
```

Use `mix test.peer` for node tests and `mix test.all` for all active tests. See [testing](../guides/testing.md), [example instructions](AGENTS.md), and [example tests](../test/examples/README.md). Keep source, tests, and README claims in the same change.
