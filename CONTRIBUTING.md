# Contributing

## Setup

```sh
mise install
```

`mise install` fetches the pinned Erlang, Elixir, and gitleaks versions
from `mise.toml`.

## Before every commit

```sh
mise run ci
```

`mise run ci` must pass — format check, `mix compile --warnings-as-errors`,
`credo --strict`, `mix test --warnings-as-errors`, and a gitleaks scan. Fix
any failure locally before committing; do not push past a red gate.

## Running a single test file

```sh
mise exec -- mix test test/typesafe/client_test.exs
```

Add `--max-cases 4` to reproduce the concurrency shape of a shared CI
runner rather than a full local core count.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `docs:`, `test:`, `chore:`, ...). Do not add
`Co-Authored-By` or other attribution trailers.

## Tests

This project practices test-driven development. New behavior needs a
failing test first; a bug fix needs a test that reproduces the bug before
the fix lands. No bang (`!`) functions in tests or library code — pattern
match `{:ok, _}` / `{:error, _}` instead.
