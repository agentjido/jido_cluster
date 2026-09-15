# Jido Cluster Agent Guide

## Commands

- `mix setup` - install dependencies and git hooks
- `mix test` - run unit tests (peer and example tags are excluded)
- `mix test.peer` - run local multi-node tests
- `mix test.examples` - run living example tests
- `mix test.all` - run all active tests
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

## Design documents

- Start with `docs/design/README.md` for purpose and ownership decisions.
- Mark proposals, accepted decisions, and implemented evidence separately.
- Keep distributed identity, location, and write authority separate.
- Do not treat issue ideas or core reference requirements as implemented features.

## Testing

- Unit tests should mirror `lib/` structure.
- Distributed behavior should be covered in `test/jido_cluster/distributed/`.
- Follow `examples/AGENTS.md` and `test/AGENTS.md` when adding living docs.
- Mirror example source folders under `test/examples/` and use only `:example`.
- Use `JidoCluster.Test.ClusterCase` for isolated local Erlang nodes and checked cleanup.
- Use `JidoCluster.Test.Eventually` for bounded eventual assertions.

## Commit Style

Use Conventional Commits, for example:

- `feat(instance_manager): add keyed cross-node call wrappers`
- `fix(rebalancer): avoid migration on non-shared backends`
- `test(cluster): add singleton race coverage across nodes`

## Release Hygiene

- Do not modify `CHANGELOG.md`; release notes are generated from Git history during release, so keep changes focused on proper Conventional Commits.
