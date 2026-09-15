# Test instructions

- Run commands inside this package, using the pinned tools and local V3 paths.
- Put unit tests under `test/jido_cluster/` to match runtime code.
- Put node tests under `test/jido_cluster/distributed/`. Use `JidoCluster.Test.ClusterCase`, which adds `:peer`.
- Put living example tests under `test/examples/`, matching the source folder. Use only `:example`. For node examples, use `JidoCluster.Test.ClusterCase, tag: :example`.
- Do not add both tags. ExUnit includes tags with OR semantics.
- Put shared helpers under `test/support/`. Do not compile test files on remote nodes.
- Use independent peer channels for concurrent requests from different nodes.
- Register node cleanup before remote setup can fail. Use monitors and bounded timeouts to check cleanup.
- Assert public manager or AgentServer results. Use state barriers or monitor messages. A fixed sleep does not prove completion.
- Run `mix test`, `mix test.peer`, and `mix test.examples` for separate groups. Run `mix test.all` for all active tests before a runtime commit.
- Keep README claims and tests in the same change. Follow [example instructions](../examples/AGENTS.md).
