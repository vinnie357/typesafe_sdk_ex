# ADR 0003: Public API is a facade returning tagged tuples

**Status:** Accepted
**Date:** 2026-09-17

## Context

The JS SDK exposes a `TypeSafeClient` class, a lazy `APIPromise`, and a `Models` namespace (`src/index.ts:1-22`). It throws on bad configuration (`client.ts:265`) and on bad requests. Elixir has no class, no thenable, and a convention against bang functions in this codebase. The first PR review also found that splitting one large module had made the internals public, documented API (PR #1 review, R6).

## Decision

1. `TypeSafe` is the facade. It delegates to `TypeSafe.Config`, `TypeSafe.HTTP`, and `TypeSafe.Questions`. These, `TypeSafe.Errors`, and `TypeSafe.Retry` carry `@moduledoc false`.
2. The public modules are `TypeSafe`, `TypeSafe.Client`, `TypeSafe.RetryPolicy`, `TypeSafe.Error`, and the ten structs under `TypeSafe.Error.*`.
3. `new/1`, `system_one/3`, and `list_models/2` return `{:ok, value}` or `{:error, exception}`. The SDK defines no bang variants.
4. Invalid options, an invalid request, and an unexpected `/v1/models` shape return `{:error, %TypeSafe.Error{}}`. JS throws in these cases. Call `opts` that is not a keyword list returns the same, with the messages `list_models/2 requires a keyword list of options` and `system_one/3 requires a keyword list of options`, mirroring `new/1`'s `new/1 requires a keyword list of options`.
5. `new/1` returns `{:error, _}` for a non-keyword `opts`, an unknown option key, a wrong-typed option value, and a `get_env` function that returns a non-string. ADR 0004 lists the checks.
6. These paths raise today. Issues #7 and #12 track the ones marked with an issue number; the rest are by design:
   - `new/1` with a `get_env` function that itself raises.
   - `new/1` with an unknown key inside `req_options`: Req raises `ArgumentError` (#7).
   - A call with `req_options: [http_errors: :raise]` after a non-2xx response raises `RuntimeError` (#7).
   - A first call on a client built with `finch: [name: ...]` or the deprecated `finch: :name` raises `ArgumentError` (#7).
   - `system_one/3` with a request that is not a map raises `FunctionClauseError`.
   - A builder call that fails its guard raises `FunctionClauseError` (ADR 0011).
   - A non-2xx error body whose validation `loc` holds a JSON object, such as `{"detail":[{"msg":"m","loc":[{"a":1}]}]}`, raises `Protocol.UndefinedError` while the message is built. The server controls the body, so this blocks v0.2.0 (#12: https://github.com/vinnie357/typesafe_sdk_ex/issues/12).
   - A first argument that is not a `%TypeSafe.Client{}` (`list_models(:x)`, `system_one(:x, request)`) raises `FunctionClauseError` (#12).
   - Request content that JSON cannot encode (a PID or a tuple in `state`, or in `noul` criteria) raises `Protocol.UndefinedError` from the JSON encoding (#12).
   The list comes from running each case on 2026-09-30; it is not a proof that no other path raises.
7. `with_response: true` returns `%{data: term, response: %Req.Response{}, request_id: String.t() | nil}` and replaces `APIPromise` and `.withResponse()` (`api-promise.ts:7-14`). The SDK checks the option is a boolean before sending a request.
8. `list_models/2` replaces `client.models.list` (`models.ts:15-27`). The SDK defines no `Models` module. It returns the list under `"models"`. Any other body shape returns `{:error, %TypeSafe.Error{}}`.
9. Responses are decoded, string-keyed maps. The SDK validates none of them except the `/v1/models` shape.
10. The SDK defines no answer structs and no typed accessors. `@type` specs document shapes only.
11. `%TypeSafe.Client{}` holds `base_url`, `default_model`, `log_level`, `retry`, `timeout`, `default_headers`, and `req`. The API key lives only in `req`, as the `authorization` header.
12. Default `inspect/1` of a client never prints the key, because Req's `Inspect` for `Req.Request` redacts the `authorization` header (`req@0.7.4 lib/req/request.ex:1157-1165`). `inspect(client, structs: false)` and `client.req.headers` expose the key. The `TypeSafe.Client` moduledoc and `SECURITY.md` say so.
13. `TypeSafe.version/0` returns `Application.spec(:typesafe_sdk_ex, :vsn)`, and falls back to the compile-time version when the application is not loaded.
14. Public `@doc` and `@moduledoc` text cites no internal document.

## Consequences

### Positive

- Callers pattern-match on results and never rescue for expected failures.
- Internal modules can change without breaking callers.
- The key stays out of default `inspect` output, logs, and crash reports that print the client.

### Negative

- The `new/1` doc claims it "never raises on bad input", which is broader than the built behavior. The paths in decision 6 raise. Issue #7 tracks the `req_options` cases (https://github.com/vinnie357/typesafe_sdk_ex/issues/7) and issue #12 tracks the other paths (https://github.com/vinnie357/typesafe_sdk_ex/issues/12).
- Callers get maps, not structs, so a typo in a key returns `nil` and no compile-time error. The SDK trades that for a smaller surface and no response validation.
- A `system_one/3` call with a `nil` request raises `FunctionClauseError`. The first PR review accepted this as a caller error outside the documented contract.

## Alternatives considered

- **Bang variants beside the tagged tuples.** Rejected: the codebase bans bang functions.
- **Answer structs and typed accessors like Python's `nouls`, `choices`, `scores`** (`sdk/python/api/types/responses.md`). Rejected: the JS SDK returns unvalidated JSON, and the port follows it (ADR 0001).
- **A `TypeSafe.Models` module.** Rejected: the JS `Models` class is a namespace only (`models.ts:7-18`).
- **Keep the single-module implementation.** Rejected: one module held every concern and the review projected it past 1000 lines once retries and logging landed (PR #1 review, N10).

## References

- JS: `src/index.ts:1-22`, `src/client.ts:265`, `src/resources/models.ts:7-27`, `src/api-promise.ts:7-14`, `src/client.ts:236-255` (readonly properties, mapped to the struct fields), `src/types.ts:73-115` (answer shapes), `src/types.ts:117-142` (answer type inference, not ported), `test/client.test.ts:82-87`, `test/client.test.ts:164-185`.
- Endpoints: `POST /v1/systemone` (https://docs.typesafe.ai/api.md, `api.md:L11-L17`) and `GET /v1/models` (https://docs.typesafe.ai/models.md).
- Req redaction: `req@0.7.4 lib/req/request.ex:1157-1165`.
- PR #1 review round 1, findings N4, N6, N9, N10, B1: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5714770534
- PR #1 review round 2, findings R4 and R6: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5715301129
- PR #1 review round 3, findings D5 (public docs cite no internal document) and D6: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5722393470
- Open `req_options` gaps: https://github.com/vinnie357/typesafe_sdk_ex/issues/7
