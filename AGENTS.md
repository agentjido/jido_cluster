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
- Jido owns Agent execution, checkpoint encoding, and commit revisions.
- Use `Jido.Persistence.Store` for journal byte I/O and core persistence adapters.
  Cluster owns journal encoding, bounds, revision checks, and recovery policy.
- Put cluster membership, placement, and activation lifetime in this package.
- Named Cluster instances own shared scope admission, journal intent, and recovery.
- `Deployment` is internal and requires a scope-confirmed reservation and activation guard.
- Do not add standalone managers, placement authorities, or legacy compatibility APIs.
- Keep one repair owner for a deployed Topology. Use the public core Controller with manual repair; preserve uncertain source retirement.
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

- Keep the public entry point in `lib/jido_cluster.ex` and supporting modules in
  `lib/jido_cluster/`. Keep the public `Jido.Cluster` module namespace.
- Unit tests should mirror `lib/jido_cluster/` under `test/jido_cluster/`.
- Distributed behavior should be covered in `test/jido_cluster/distributed/`.
- Follow `examples/AGENTS.md` and `test/AGENTS.md` when adding living docs.
- Mirror example source folders under `test/examples/` and use only `:example`.
- Run examples through these test cases. Do not add separate `demo.exs` runners.
- Keep setup used only by example tests in `test/examples/support/`.
- Use `JidoCluster.Test.ClusterCase` for isolated local Erlang nodes and checked cleanup.
- Use `JidoCluster.Test.Eventually` for bounded eventual assertions.

## Commit Style

Use Conventional Commits, for example:

- `feat(entity): add domain-key calls through a named scope`
- `fix(recovery): retain uncertain host claims`
- `test(cluster): add singleton race coverage across nodes`

## Release Hygiene

- Do not modify `CHANGELOG.md`; release notes are generated from Git history during release, so keep changes focused on proper Conventional Commits.
