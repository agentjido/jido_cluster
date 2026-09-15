# Example tests

Tests mirror the [numbered examples](../../examples/README.md). Agent and Topology definitions live in that source catalog. These test cases are the run path for each example and check its stated result through public APIs.

```sh
mise exec -- mix test.examples
mise exec -- mix test.all
```

All example tests use only `:example`, including tests that start nodes. The normal unit run excludes them. Example-only fixtures live in `test/examples/support/`: the [definition builder](support/definition.ex), [Topology case](support/topology_case.ex), and [placement case](support/placement_case.ex). General node setup is in [ClusterCase](../support/cluster_case.ex). Follow the [test instructions](../AGENTS.md) and [example instructions](../../examples/AGENTS.md).
