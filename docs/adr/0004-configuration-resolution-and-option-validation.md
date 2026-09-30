# ADR 0004: Configuration resolution and option validation

**Status:** Accepted
**Date:** 2026-09-17; amended 2026-09-30 (issue #12)

## Context

The JS constructor resolves four settings from an explicit option, then an environment variable, then a default (`src/client.ts:267-289`, `src/env.ts:1-23`). It treats only `undefined` as "not given", because it uses `??`. It throws on any invalid value. The first PR review found `new/1` accepting or crashing on bad values (PR #1 review, B5) and then rejecting an explicit `nil` that JS treats as not given (R1).

## Decision

1. `api_key`, `base_url`, `default_model`, and `log_level` resolve in this order: the option, then the environment variable, then the default.
2. The environment variables are `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, `TYPESAFE_DEFAULT_MODEL`, and `TYPESAFE_LOG_LEVEL`. The defaults are none (required), `https://api.typesafe.ai`, `jev-latest`, and `:warning`.
3. `new/1` reads the environment through the `:get_env` option: a 1-arity function that defaults to `&System.get_env/1`. It never reads the process environment otherwise.
4. `get_env` must return a string or `nil`. Any other return value gives `{:error, %TypeSafe.Error{}}` that names the variable.
5. The SDK trims environment values, and a blank value counts as unset (`env.ts:16-19`). Trimming follows JS `String#trim` (decision 15).
6. An explicit `nil` option counts as not given for the four settings above. `default_headers`, `req_options`, and `get_env` reject `nil`.
7. An explicit blank or whitespace-only `api_key`, including one made only of U+FEFF (decision 15), is rejected with the missing-key error, `{:error, %TypeSafe.Error{message: "TYPESAFE_API_KEY is required."}}`, even when `TYPESAFE_API_KEY` is set (operator rulings: PR #1 review N7, and the ruling recorded on issue #10). `new/1` also trims a non-blank `api_key` option.
8. The SDK strips trailing slashes from `base_url`, whether it came from the option or the environment.
9. The `log_level` option takes one of `:debug`, `:info`, `:warning`, `:error`, `:off`. Any other value returns `{:error, _}`.
10. `TYPESAFE_LOG_LEVEL` accepts `debug`, `info`, `warn`, `warning`, `error`, and `off`, in any letter case. `warn` and `warning` both map to `:warning`.
11. An unrecognized `TYPESAFE_LOG_LEVEL` falls back to `:warning` without an error.
12. `log_level` has no effect today: the SDK does not log.
13. `new/1` checks option keys with `Keyword.validate/2` and returns `{:error, _}` naming unknown keys. A key given twice is caught first (decision 16).
14. `new/1` checks option values with guard clauses and returns `{:error, %TypeSafe.Error{}}` that names the option. A non-keyword `opts` returns `{:error, _}` too.
15. Trimming strips U+FEFF (the byte order mark) as well as whitespace, for the `api_key` option and for every environment value. `String.trim/1` strips Unicode White_Space only, and U+FEFF is not in that set, while JS `trim` strips it (ECMAScript `WhiteSpace` includes U+FEFF). A BOM-only `api_key` option is rejected with the missing-key error even when `TYPESAFE_API_KEY` is set. A BOM-only environment value counts as unset. A BOM around real text is removed: `"\u{FEFF}k\u{FEFF}"` becomes `"k"`. Without this the SDK sent `Bearer \u{FEFF}` and the server saw an invalid key. Only the `api_key` option is trimmed among the options; `base_url` and `default_model` options are used as given.
16. A key given twice, at the top level of `new/1` or in the options of `list_models/2` and `system_one/3`, returns `{:error, %TypeSafe.Error{message: "<key> given more than once"}}`, for example `timeout given more than once`. `Keyword.validate/2` reports a repeated known key as unknown (`Unknown option(s): timeout`), which misleads. The check runs before the unknown-key check, as for `retry` (ADR 0007 decision 4), so `[bogus: 1, timeout: 5, timeout: 6]` reports `timeout`. The first repeated key in option order names the error, as `RetryPolicy.merge/2` does. A repeated `retry:` key reports `retry given more than once`; a repeated key inside one `retry:` list keeps `retry.<key> given more than once`.

## Consequences

### Positive

- A misconfiguration returns an error at `new/1`, naming the option, instead of crashing on the first request.
- The common idiom `base_url: Application.get_env(:my_app, :typesafe_base_url)` works when the config is unset, because `nil` falls through to the environment.
- Tests inject the environment and never mutate process state (ADR 0012).

### Negative

- Decisions 7 and 11 deviate from JS. JS keeps an explicit `""` and sends `Bearer `. JS throws `Invalid log level "loud" from TYPESAFE_LOG_LEVEL` and names the source (`logging.ts:13-18`, `client.ts:157-162`, `test/client.test.ts:119-128`). The port cannot validate the environment level yet, because nothing reads it. When logging is built, decision 11 needs a new ADR.
- The Python SDK documents that an explicitly empty key does not fall back to the environment (https://docs.typesafe.ai/sdk/python/usage.md, "Environment variables"). Decision 7 matches it: a blank `api_key` option is rejected even when the variable is set.
- The `log_level` option accepts atoms only. `log_level: "warn"` returns `{:error, _}`.
- Decision 16 has no JS counterpart: a JS options object cannot hold a key twice.
- Decision 15 extends the trim to the `api_key` option, which JS never trims (`client.ts:270` passes it to `fromCodeOrEnv` as given). It follows decision 7, which already trims a non-blank `api_key` option. Verified on Node 24.19.0: `"\uFEFFk\uFEFF".trim()` is `"k"`, so JS trims a BOM in an environment value (`env.ts:18`).

## Alternatives considered

- **Accept an explicit blank `api_key` like JS.** Rejected by operator decision: JS then sends `Bearer ` (PR #1 review, N7).
- **Throw on option errors like JS.** Rejected: ADR 0003.
- **Validate values with NimbleOptions.** Rejected: ADR 0002.

## References

- JS: `src/env.ts:2-11` (names), `src/env.ts:16-19` (trim and blank), `src/env.ts:22-23` (`??`), `src/client.ts:42` (default model), `src/client.ts:48-52`, `src/client.ts:157-162`, `src/client.ts:164,271-273` (trailing slashes), `src/logging.ts:5-18`, `test/client.test.ts:100-103`, `test/client.test.ts:113-117`, `test/client.test.ts:119-128`.
- PR #1 review round 1, findings B5, N3, N7: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5714770534
- PR #1 review round 2, findings R1 and R4: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5715301129
- Default base URL: https://docs.typesafe.ai/api.md (`api.md:L14`)
- Python log level spelling: https://docs.typesafe.ai/sdk/python/usage.md
