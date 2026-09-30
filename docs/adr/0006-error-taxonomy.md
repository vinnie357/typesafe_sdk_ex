# ADR 0006: Error taxonomy

**Status:** Accepted
**Date:** 2026-09-17

## Context

The JS SDK maps each non-2xx status to an `APIError` subclass, wraps transport failures in `APIConnectionError`, and makes `APITimeoutError` a subclass of it (`src/errors.ts:42-115`). Elixir has no inheritance. Callers match on `{:error, exception}`, so the taxonomy must give them one struct per case they branch on, with the same fields each time.

## Decision

1. The SDK returns one `defexception` per status class, mapped as JS `fromResponse` does (`errors.ts:69-78`):

   | Status | Struct under `TypeSafe.Error` |
   |---|---|
   | 400 | `BadRequest` |
   | 401 | `Authentication` |
   | 403 | `PermissionDenied` |
   | 404 | `NotFound` |
   | 422 | `UnprocessableEntity` |
   | 429 | `RateLimit`, with `retry_after_ms` |
   | 500 and above, including 529 | `InternalServer` |
   | any other non-2xx status, such as 409 or 418 | `API` |

2. Every HTTP error struct carries `status`, `body`, `headers`, `request_id`, and `message` (`errors.ts:42-58`). `body` is decoded JSON, text, or `nil`. `headers` is Req's header map. `request_id` is the `x-typesafe-request-id` value or `nil`.
3. `RateLimit.retry_after_ms` uses the parser in ADR 0009 (`errors.ts:92-95`).
4. A transport failure returns `TypeSafe.Error.Connection` with `message: "Connection error: <cause>"` and `reason` set to the `%Req.TransportError{}` reason, or `nil` for any other exception (`client.ts:440-443`).
5. A transport failure with reason `:timeout` returns `TypeSafe.Error.Timeout` with `message: "Request timed out after <ms>ms."` and `timeout_ms` (ADR 0010).
6. `Timeout` and `Connection` are separate structs. The SDK defines no shared base struct: `TypeSafe.Error` and every struct above are unrelated exceptions.
7. `TypeSafe.Error` carries `message` for configuration failures, validation failures, and an unexpected `/v1/models` body shape.
8. The message format is `"<status> <detail>"`. The SDK extracts the detail in this order (`errors.ts:16-37`):
   1. the body is a non-empty string: the string
   2. `error` is a string
   3. `error.message`
   4. `message`
   5. `detail` is a string
   6. `detail.message`
   7. `detail` is a list: each entry's `loc`, minus `"body"`, joined with `.`, then `: msg`, entries joined with `"; "`
9. With no extracted detail and a `nil` body, the message is `"<status> status code (no body)"`.
10. With no extracted detail and a body, the message is the original body text, cut to 200 characters plus `…` (`errors.ts:60-66`).
11. Decision 10 deviates from JS, which re-stringifies the parsed body. Stdlib `JSON` offers only bang encoders (`JSON.encode!/1`, `JSON.encode_to_iodata!/1`), so the SDK avoids re-encoding. The message equals JS output when the server sends compact JSON, as in `test/errors.test.ts:91-95`. For `{ "code" : 7 }` it keeps the spacing.

## Consequences

### Positive

- One `case` on `{:error, exception}` covers every outcome with a struct per branch. The README lists the same ten structs.
- The HTTP error structs hold response headers, not request headers. The round 3 probe of PR #1 found the API key in no error struct, message, or `inspect` output.

### Negative

- Two message gaps against JS exist and no test pins them. An empty-string `error`, `message`, or `detail` value yields the message `"<status> "`, where JS falls through to the raw-body form because an empty detail is falsy. A JSON `null` body reads as no body, where JS reports `"<status> null"`.
- Code cannot match all SDK errors with one struct pattern, only on the tuple.
- The public `TypeSafe.Error.Timeout` moduledoc is stale. It says `timeout_ms` is `client.timeout` "until ... a per-call override" lands, and that the full response did not arrive. The per-call override exists, and the value bounds each socket read (ADR 0010).

## Alternatives considered

- **A shared `TypeSafe.Error.Base` struct.** Rejected: Elixir has no inheritance, and a base struct would not let a caller pattern-match a subtype.
- **Fold `Timeout` into `Connection` with a flag.** Rejected: JS keeps them distinct because retry behavior differs (ADR 0008), and callers branch on them.
- **Re-encode the parsed body for the fallback message like JS.** Rejected: it needs an encoder the stdlib exposes only as a bang function, and the original text is more faithful.
- **Map only the statuses the docs list (401, 422, 429, 529).** Rejected: JS maps 400, 403, and 404 as well, and the JS live test expects `400 Unknown model: no-such-model` (`test/integration/api.integration.ts:116-127`).

## References

- JS: `src/errors.ts:5` (`TypeSafeError`), `src/errors.ts:16-37,42-58,60-66,69-78,92-95,100-115`, `src/client.ts:440-443`, `test/errors.test.ts:20-40`, `test/errors.test.ts:42-133`, `test/integration/api.integration.ts:116-127`.
- Docs: https://docs.typesafe.ai/api.md (error table).
- PR #1 review round 1, finding B1 (a bad `/v1/models` shape raises `MatchError`): https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5714770534
- PR #1 review round 3, finding D1 (the README and `TypeSafe.Error` moduledoc described the pre-taxonomy world): https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5722393470
