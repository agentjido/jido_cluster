# Jido Cluster Agent Guide

## Commands

- `mix setup` - install dependencies and git hooks
- `mix test` - run test suite
- `mix coveralls` - run tests with coverage checks
- `mix quality` - run formatter, compile, credo, dialyzer, doctor
- `mix docs` - build docs

## Standards

- Target Elixir `~> 1.18`.
- Add `@moduledoc` for public modules.
- Add `@doc` and `@spec` for public functions.
- Prefer tagged tuple returns (`{:ok, value}` / `{:error, reason}`).
- Keep distributed behavior deterministic and testable.

## Testing

- Unit tests should mirror `lib/` structure.
- Distributed behavior should be covered in `test/jido_cluster/distributed/`.
- Use `JidoCluster.Test.Eventually` for bounded eventual assertions.

## Commit Style

Use Conventional Commits, for example:

- `feat(instance_manager): add keyed cross-node call wrappers`
- `fix(rebalancer): avoid migration on non-shared backends`
- `test(cluster): add singleton race coverage across nodes`
