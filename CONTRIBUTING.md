# Contributing

## Setup

```sh
mise install
```

`mise install` fetches the pinned Erlang, Elixir, gitleaks, and nushell
versions from `mise.toml`. The audit scripts and their tests are nushell.

## Before every commit

```sh
mise run ci
```

`mise run ci` must pass — the `mix hex.audit` and `mix deps.audit` advisory
audits, the advisory exception review check, the Erlang/OTP CVE floor check
(`audit:otp`), the audit script tests, format check,
`mix compile --warnings-as-errors`, `credo --strict`,
`mix test --warnings-as-errors`, and a gitleaks scan. The Hex and deps audits
need network. The audits run in `mise run ci` locally and on the pinned CI leg
only. `audit:otp` fails when the erlang pin in `mise.toml` or the running `erl`
is below the floor in `scripts/otp-audit.nu`, or when the two differ. A
`mise.local.toml` or `.tool-versions` override of erlang therefore fails
`mise run ci`. See
[`docs/security/advisory-exceptions.md`](docs/security/advisory-exceptions.md)
before you allow-list an advisory. Fix
any failure locally before committing; do not push past a red gate.

## Running a single test file

```sh
mise exec -- mix test test/typesafe/client_test.exs
```

Add `--max-cases 4` to reproduce the concurrency shape of a shared CI
runner rather than a full local core count.

## Design decisions

Decisions and deliberate deviations from the JS SDK are recorded in
[`docs/adr/`](docs/adr/README.md). Add or amend an ADR in the same PR as the
change.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `docs:`, `test:`, `chore:`, ...). Do not add
`Co-Authored-By` or other attribution trailers.

## Tests

This project practices test-driven development. New behavior needs a
failing test first; a bug fix needs a test that reproduces the bug before
the fix lands. No bang (`!`) functions in tests or library code — pattern
match `{:ok, _}` / `{:error, _}` instead.
