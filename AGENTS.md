# Jido Cluster Agent Guide

## Commands

- `mix setup` - install dependencies and git hooks
- `mix test` - run test suite
- `mix quality` - run formatter, compile, credo, doctor
- `mix dialyzer` - run type analysis
- `mix docs` - build docs

## Standards

- Work on `v3-spike` for the V3 foundation.
- Use the local sibling Jido V3 dependencies declared in `mix.exs`.
- `archive/v2/` is retained reference code. Do not use it as the current contract.
- Jido owns Agent execution, checkpoint encoding, and commit revisions.
- Put cluster membership, placement, and activation lifetime in this package.
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

## Release Hygiene

- Do not modify `CHANGELOG.md`; release notes are generated from Git history during release, so keep changes focused on proper Conventional Commits.
