# Jido Cluster examples

These examples are living documentation. Each example has source code, a run command, and tests that check its stated result. The folder numbers set the reading order.

| Group | Example | Learn |
| --- | --- | --- |
| [01 Cluster](01_cluster/README.md) | [01_01 Keyed counter](01_cluster/01_01_keyed_counter/README.md) | Route commands across nodes and restore a saved counter after owner loss |

Example source code compiles in `dev` and `test`. It does not compile in `prod`. Tests mirror each numbered folder under `test/examples/` and use only the `:example` tag. The normal test command excludes this tag.

Run from `jido_cluster`:

```sh
mise exec -- mix test.examples
mise exec -- mix run examples/01_cluster/01_01_keyed_counter/demo.exs
```

Use `mix test.peer` for node tests and `mix test.all` for all active tests. See [testing](../guides/testing.md), [example instructions](AGENTS.md), and [example tests](../test/examples/README.md). Keep source, tests, and README claims in the same change.
