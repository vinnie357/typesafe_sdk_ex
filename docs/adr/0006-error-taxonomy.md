# ADR 0006: Error taxonomy

**Status:** Accepted
**Date:** 2026-09-17; amended 2026-09-30 (issue #12)

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
4. A transport failure returns `TypeSafe.Error.Connection` with `message: "Connection error: <cause>"` and `reason` set to the `%Req.TransportError{}` reason, or `nil` for any other exception (`client.ts:440-443`). Decision 15 adds the reason `:pool_timeout`.
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
   7. `detail` is a list: each entry's `loc`, minus `"body"`, joined with `.` (decision 14), then `: msg`, entries joined with `"; "`
9. With no extracted detail and an empty raw body (`nil` or `""`), the message is `"<status> status code (no body)"`. A JSON `null` body is not empty (decision 13).
10. With no extracted detail and a non-empty raw body, the message is the original body text, cut to 200 characters plus `…` (`errors.ts:60-66`). A non-binary body from a custom adapter has no original text, so the SDK uses its `inspect/1` form.
11. Decision 10 deviates from JS, which re-stringifies the parsed body. Stdlib `JSON` offers only bang encoders (`JSON.encode!/1`, `JSON.encode_to_iodata!/1`), so the SDK avoids re-encoding. The message equals JS output when the server sends compact JSON, as in `test/errors.test.ts:91-95`. For `{ "code" : 7 }` it keeps the spacing.

12. An extracted detail that is an empty string counts as no detail, and extraction stops at the first present string. The message then takes the raw-body form of decision 10 (`errors.ts:20-24` return the empty string, `errors.ts:62` treats it as falsy, `errors.ts:64-65` build the raw form). A later non-empty field does not win: `{"error":"","message":"m"}` gives `500 {"error":"","message":"m"}`. The rule covers `error`, `error.message`, `message`, `detail`, and `detail.message`. This deviates from JS in two edge cases. A body that is the JSON string `""` gives `500 ""`, because the SDK keeps the original text (decision 10) where JS gives `500 ` (an empty string). A body of `" null "` with surrounding whitespace gives the original text, `500  null ` (the padding is kept), where JS parses it to `null` and gives `500 null`. In both cases `body` is the decoded value.
13. A body that is the JSON text `null` gives the message `"<status> null"` and `body: nil`, where JS gives `body: null` (`client.ts:478` with a JSON content type, `client.ts:485` without one; `errors.ts:63-64`). An empty body still gives decision 9 (`client.ts:474`).
14. A validation `loc` entry renders as JS `Array#join` does (`errors.ts:31`: `e.loc.filter((x) => x !== "body").join(".")`), for every JSON value the server can send. The server controls the body, so no shape may raise (ADR 0003 decision 6, issue #12). The `"body"` entries are dropped at the top level only. Then each element renders as: a string, itself; an integer, its decimal digits; `true` and `false`, their names; `null`, the empty string; a list, its elements rendered by this rule and joined with `,`, without dropping `"body"`; an object, the literal text `[object Object]`. An empty result means no `loc`, and the entry is the bare `msg`. Examples, each checked against Node 24.19.0: `[{"a":1}]` gives `[object Object]`, `[[1,2]]` gives `1,2`, `[1,true,false,null]` gives `1.true.false.`, `["body",["body","q"]]` gives `body,q`, and `[null]`, `[[]]`, and `[]` give the empty string. A `loc` that is not a list is ignored. The port mirrors the literal `[object Object]` on purpose: it costs one clause, the text is identical to JS for the same server response, and a "saner" rendering (an `inspect` or JSON form of the object) would put arbitrary server-controlled structure into the message and would need its own size and format rules. Two deviations, both from Elixir number types. A JSON number that decodes to an Elixir float (a fraction part or an exponent) renders with `to_string/1`, so `1.5` gives `1.5`, `1.0` gives `1.0`, and `1e20` gives `1.0e20`, where JS gives `1`, `1`, and `100000000000000000000`. An integer renders exactly, so `12345678901234567890` gives `12345678901234567890`, where JS, which holds it as a double above 2^53, gives `12345678901234567000`. Before this decision the SDK raised `Protocol.UndefinedError` on an object, put control bytes in the message for a nested list (a charlist conversion), and raised `ArgumentError` on a nested list that holds `null`, such as `[[null]]`. A top-level `null` already rendered as the empty string.
15. A pool-checkout timeout returns `TypeSafe.Error.Connection` with `reason: :pool_timeout` and `message: "Connection error: connection pool exhausted (no connection available within the pool timeout)"`. When Finch's pool cannot hand out a connection within its `pool_timeout` (default 5000 ms), Finch does not return an error: it re-raises the NimblePool checkout exit as a `RuntimeError` whose message starts `Finch was unable to provide a connection within the timeout` (`finch@0.24.0 lib/finch/http1/pool.ex:81-89`), and Req lets it propagate. A design probe of 60 concurrent `system_one/3` calls on the default pool produced 10 raised `RuntimeError`s, and one with `size: 100` produced none (both recorded on issue #12; operator decision 2026-09-30: this blocks v0.2.0). The SDK rescues only that exception, recognised by that message prefix, around the request, and returns the struct. Any other `RuntimeError`, and any other exception, still raises. The SDK does not retry it, whatever the policy, and that includes a pool timeout on a retry attempt: it replaces the status error from the earlier attempt, so a 503 followed by a pool timeout returns the pool timeout and the 503 is lost (observed in the PR #16 review): the error never reaches `decide/2` (ADR 0007), and an immediate retry would queue behind the same saturated pool. `Timeout` stays for a receive timeout; it is a different failure (ADR 0010). The fix for a caller is a larger pool, `req_options: [finch: [size: n]]`, or a longer wait, `req_options: [finch: [pool_timeout: ms]]`; the README documents both.

## Consequences

### Positive

- One `case` on `{:error, exception}` covers every outcome with a struct per branch. The README lists the same ten structs.
- The HTTP error structs hold response headers, not request headers. The round 3 probe of PR #1 found the API key in no error struct, message, or `inspect` output.

### Negative

- Code cannot match all SDK errors with one struct pattern, only on the tuple.

## Alternatives considered

- **A shared `TypeSafe.Error.Base` struct.** Rejected: Elixir has no inheritance, and a base struct would not let a caller pattern-match a subtype.
- **Fold `Timeout` into `Connection` with a flag.** Rejected: JS keeps them distinct because retry behavior differs (ADR 0008), and callers branch on them.
- **Re-encode the parsed body for the fallback message like JS.** Rejected: it needs an encoder the stdlib exposes only as a bang function, and the original text is more faithful.
- **Map only the statuses the docs list (401, 422, 429, 529).** Rejected: JS maps 400, 403, and 404 as well, and the JS live test expects `400 Unknown model: no-such-model` (`test/integration/api.integration.ts:116-127`).

## References

- JS: `src/errors.ts:5` (`TypeSafeError`), `src/errors.ts:16-37,31,42-58,60-66,69-78,92-95,100-115`, `src/client.ts:440-443`, `test/errors.test.ts:20-40`, `test/errors.test.ts:42-133`, `test/integration/api.integration.ts:116-127`.
- Docs: https://docs.typesafe.ai/api.md (error table).
- PR #1 review round 1, finding B1 (a bad `/v1/models` shape raises `MatchError`): https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5714770534
- PR #1 review round 3, finding D1 (the README and `TypeSafe.Error` moduledoc described the pre-taxonomy world): https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5722393470
