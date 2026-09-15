# Example tests

Tests mirror the [numbered examples](../../examples/README.md). Each test checks the result stated in its example README through public APIs.

```sh
mise exec -- mix test.examples
mise exec -- mix test.all
```

All example tests use only `:example`, including tests that start nodes. The normal unit run excludes them. Shared node setup is in [ClusterCase](../support/cluster_case.ex). Follow the [test instructions](../AGENTS.md) and [example instructions](../../examples/AGENTS.md).
