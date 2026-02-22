# Contributing to Jido Cluster

## Prerequisites

- Elixir `~> 1.18` (1.19 recommended)
- Erlang/OTP 27 or 28

## Setup

```bash
mix setup
```

## Quality Gates

Run before opening a pull request:

```bash
mix quality
mix test
```

`mix quality` runs:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix credo --min-priority higher`
- `mix dialyzer`
- `mix doctor --raise`

## Testing

```bash
mix test
mix coveralls
```

Distributed tests use `ex_unit_cluster` and `:peer` and run in the normal ExUnit suite.

## Commit Messages

Use Conventional Commits:

- `feat`: new functionality
- `fix`: bug fixes
- `docs`: documentation updates
- `test`: test changes
- `refactor`: non-feature/non-fix code changes
- `chore`: tooling/maintenance
- `ci`: CI/CD workflow changes

Examples:

```bash
git commit -m "feat(rebalancer): add leader-only sync trigger for tests"
git commit -m "fix(storage): enforce expected_rev conflict handling"
```

## Pull Requests

- Keep changes focused and small.
- Add or update tests for behavior changes.
- Update `CHANGELOG.md` for user-visible changes.
- Ensure CI is green before merge.
