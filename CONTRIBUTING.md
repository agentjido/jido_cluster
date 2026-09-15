# Contributing to Jido Cluster

## Prerequisites

- Elixir `~> 1.18` (1.19 recommended)
- Erlang/OTP 27 or 28
- Compatible sibling Jido V3 checkouts as described in `README.md`

## Setup

```bash
mise install
mise exec -- mix setup
```

## Quality Gates

Run before opening a pull request:

```bash
mix quality
mix test.all
```

`mix quality` runs:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix credo --strict`
- `mix doctor --raise`

## Testing

```bash
mix test.all
mix dialyzer
```

Distributed tests use the shared `:peer` case and the `:peer` tag. Example tests use only `:example`. The normal unit run excludes both tags. See [local testing](guides/testing.md).

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
- Update the V3 foundation guide for contract changes. Release notes are generated from Git history.
- Ensure CI is green before merge.
