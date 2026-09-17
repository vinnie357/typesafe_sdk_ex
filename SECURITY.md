# Security Policy

## Supported versions

This SDK is pre-1.0. Only the latest commit on `main` receives security
fixes; there are no tagged releases yet.

## Reporting a vulnerability

Do not open a public issue for a security report.

Report privately through [GitHub Security
Advisories](https://github.com/vinnie357/typesafe_sdk_ex/security/advisories/new)
on this repository.

Include the affected version or commit, a reproduction, and the impact you
observed.

## Scope

In scope: this repository's Elixir code (`lib/`), its build and CI
configuration, and its dependencies as declared in `mix.lock`.

Out of scope: the TypeSafe API service itself, and the upstream
`typesafe-ai/typesafe-sdk-js` project this SDK is ported from.

## Handling API keys

This SDK reads `TYPESAFE_API_KEY` from the environment (or an `:api_key`
option) and never logs it. The key lives only as the `authorization` header
on the client's internal `Req.Request`; default `inspect/2` output redacts
that header. The key is still reachable by inspecting `client.req.headers`
directly or by passing `structs: false` to `inspect/2` — treat both as
sensitive operations. Never pass a key on a command line or commit it to a
config file. If a key reaches a log or a transcript, rotate it.
