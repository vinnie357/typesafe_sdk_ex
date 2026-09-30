# ADR 0002: Runtime dependency is Req only

**Status:** Accepted
**Date:** 2026-09-17; amended 2026-09-29 (`:inets`, Mint and Finch); amended 2026-09-30 (README consumer note)

## Context

The operator set the dependency constraint at the start of the port (2026-09-17): the only runtime dependency is `req`. Req brings Finch, Mint, and Jason transitively. `credo` is a CI-only tool. The constraint excludes `plug`, `ex_doc`, Mox, NimbleOptions, and any direct Jason call.

Several JS features tempt a dependency (see the table under Decision). Each has a stdlib, OTP, or Req substitute.

## Decision

1. `req` is the only runtime dependency. `mix.exs` lists `credo` with `only: [:dev, :test], runtime: false`.
2. `lib/` and `test/` call no Jason, NimbleOptions, Mox, `Req.Test`, plug, or Timex function.
3. The SDK uses the substitutes in the table below.
4. `:inets` is listed in `extra_applications`, so a release bundles `:httpd_util`.
5. `mix.exs` declares no `mint` or `finch` constraint.
6. The CHANGELOG records the safe Mint and Finch combinations for consumers: Mint 1.10.x at 1.10.2 or later with any Finch, or Mint 1.11.x with Finch 0.24.0 or later. Mint 1.11.x with Finch 0.23.x is not safe: it can raise on the request after a receive timeout. Consumers run `mix deps.update mint finch`. `CHANGELOG.md` and the README installation section state this pairing.
7. Docs stay as `@moduledoc` and `@doc`. The SDK adds no `ex_doc` dependency.

| Concern | Mechanism |
|---|---|
| Request JSON encoding | Req's `:json` option (Req calls Jason itself; the SDK does not). |
| Response JSON decoding | `decode_body: false` plus stdlib `JSON.decode/1`, which needs Elixir 1.18 or later (`mix.exs`: `elixir: "~> 1.18"`; the CI matrix runs 1.18.5 and 1.19.5). ADR 0005 gives the reason. |
| Option key validation | `Keyword.validate/2`. Value checks are guard clauses written for the purpose. |
| Env variables | `System.get_env/1`, injected as the `:get_env` function (ADR 0004). |
| Retry-After HTTP date | `:httpd_util.convert_request_date/1` plus `NaiveDateTime`. Req's own parser lives in `Req.Utils`, which is `@moduledoc false` (`req@0.7.4 lib/req/utils.ex:2`). |
| Retry-After numbers | `Regex.run/3` plus `String.to_integer/1`, in exact integer arithmetic (ADR 0009). |
| Jitter | `:rand.uniform/0`. |
| Runtime header | `System.version/0` and `:erlang.system_info(:otp_release)`. |
| Version | `Application.spec/2`, with the compile-time version as fallback. |
| Test HTTP stubs | A Req module adapter, not `Req.Test` or Mox (ADR 0012). |

## Consequences

### Positive

- The dependency surface is one package. Consumers audit Req, Finch, Mint, and their transitive set, and nothing added by this SDK.
- Stdlib `JSON` removes the content-type coupling of Req's default decoder.

### Negative

- `JSON.decode/1` raises the Elixir floor to 1.18.
- `:inets` starts in every consumer application, not only in the SDK's own tests.
- Consumers own the Mint and Finch pairing. Mint 1.11.0 with Finch 0.23.x raised out of the SDK on a request issued after a receive timeout, and the SDK cannot pin the pair without adding phantom `mint` and `finch` dependencies that the code never calls and that need re-bumping on every advisory.
- `:httpd_util.convert_request_date/1` raises `FunctionClauseError` on short inputs. The parser rescues it (ADR 0009).
- Credo lists `:inets` in its own `extra_applications` (`deps/credo/mix.exs:170`), so a missing declaration does not fail compilation in the test environment. The test `":inets is declared in the application spec"` checks `Application.spec(:typesafe_sdk_ex, :applications)` instead.

## Alternatives considered

| Tempting dependency | Purpose | Why not |
|---|---|---|
| `plug` (for `Req.Test`), Mox | Stub HTTP in tests | `Req.Test.json/2` and `transport_error/2` require `Plug.Conn` (`req@0.7.4 lib/req/test.ex:417-419`), and the `:plug` option routes through the `Req.Plug` adapter (`lib/req.ex:604`). A module adapter needs neither (ADR 0012). |
| A clock or mock library | Fake timers (`reliability.test.ts:43`) | Delays are pure functions with `now` and `random` passed in (ADR 0012). |
| NimbleOptions | Option schema (`client.ts:70-147`) | `Keyword.validate/2` plus guards. NimbleOptions is transitive only. |
| Jason (direct) | JSON parse and stringify | Req `:json` for encoding, stdlib `JSON` for decoding, original body text for error messages (ADR 0006). |
| Timex or a date library | `Date.parse` for Retry-After (`retry.ts:46`) | `:httpd_util` from OTP. |
| `ex_doc` | TypeDoc-style API docs (`docs/typedoc.json`) | Not ported. `h/1` in IEx reads the docs. |
| Direct `mint >= 1.10.2` and `finch >= 0.24.0` constraints | Reach consumer locks | A Mint floor alone can steer a consumer to the failing pair, and a correct floor is two dependencies the code never calls. The reviewer recommended the CHANGELOG note instead. |
| Pin Mint 1.10.2 | Fix the advisories with no Finch interplay | Mint 1.11.0 carries the security fixes and upstream recommends it. Finch 0.24.0 closes the timeout interplay. |

## References

- Req, Finch, and Mint versions: `mix.lock` (Req 0.7.4, Finch 0.24.0, Mint 1.11.0, hpax 1.1.0).
- Runtime dependency constraint, Mint and Finch decision, consumer note: PR #3 review, findings 1 and 4, https://github.com/vinnie357/typesafe_sdk_ex/pull/3#issuecomment-5900903615 and re-attestation https://github.com/vinnie357/typesafe_sdk_ex/pull/3#issuecomment-5901000229
- `:inets` is started in consumers (N1): https://github.com/vinnie357/typesafe_sdk_ex/pull/4#issuecomment-5901344671
- `CHANGELOG.md`, section `[0.1.1]`: safe combinations.
- The v0.2.0 README audit that added the consumer note to the README: https://github.com/vinnie357/typesafe_sdk_ex/issues/8
