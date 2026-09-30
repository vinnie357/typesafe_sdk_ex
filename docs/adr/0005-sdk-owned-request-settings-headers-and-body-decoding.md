# ADR 0005: SDK-owned request settings, headers, and body decoding

**Status:** Accepted
**Date:** 2026-09-17; amended 2026-09-29 (retry keys, timeout keys, last-wins resolution)

## Context

The JS SDK takes a `fetch` option and builds its headers in one place (`src/client.ts:352-367`). The port maps `fetch` to `req_options`, a keyword list merged into `Req.new/1`. That list is a caller's escape hatch, and it can reach settings the SDK depends on: the base URL, the bearer header, body decoding, retries, and timeouts. A silent override breaks the SDK's own guarantees. For timeouts it makes `TypeSafe.Error.Timeout.timeout_ms` report a number that never fired (ADR 0010).

Req decodes bodies by content-type (`req@0.7.4 lib/req/steps.ex:1163-1176`), so it cannot parse JSON that arrives without one. JS parses JSON whatever the content-type (`client.ts:472-489`).

## Decision

### `req_options`

1. `TypeSafe.new/1` merges `req_options` into `Req.new/1`, then forces `base_url` and sets `decode_body: false` and `retry: false`. The SDK overrides a caller's value for these three without an error. The SDK drops a caller's `:auth` and sets the `authorization` header itself.
2. `new/1` rejects these keys with `{:error, %TypeSafe.Error{}}` that names the key: `receive_timeout`, `request_timeout`, `retry_delay`, `max_retries`, and `retry_log_level`.
3. `new/1` rejects `finch: [receive_timeout: _]` and `finch: [request_timeout: _]`. Req merges `finch:` request options over the top-level ones (`req@0.7.4 lib/req/finch.ex:237-240`).
4. `new/1` rejects `finch:` together with `connect_options:`. Req raises `ArgumentError` for the pair on the first request (`lib/req/finch.ex:546-548`).
5. `new/1` rejects a `finch:` value that is not `nil`, an atom, or a keyword list, and rejects a `req_options` value that is not a keyword list.
6. `new/1` accepts `finch: [pool_timeout: ms]` and passes `connect_options` through. A top-level `pool_timeout` passes through and prints Req's deprecation warning on every `new/1` (`lib/req.ex:550-552`). The supported route is `finch: [pool_timeout: ms]`. Connect timeouts use `connect_options: [timeout: ms]` (ADR 0010).
7. `new/1` validates `req_options` as Req resolves it. `Req.new/1` and `Req.merge/2` collapse a keyword list with last-wins (`Map.new/1`, `lib/req.ex:590-598`). Every check in decisions 2 to 5 runs on that collapsed view.
8. The invariant is: for every `req_options` that `new/1` accepts, the resolved `client.req.options` holds no `:receive_timeout` or `:request_timeout`, holds none of them inside `options[:finch]` when that is a keyword list, and never holds both `:finch` and `:connect_options`.
9. A duplicate key is judged by the value Req keeps. `[finch: [receive_timeout: 5], finch: [pool_size: 2]]` is accepted. `[finch: [pool_size: 2], finch: [receive_timeout: 5]]` is rejected. A benign duplicate such as `[finch: [pool_size: 2], finch: [pool_size: 3]]` is accepted, so `base ++ overrides` composition works.

### Known gaps in `req_options`

10. This ADR does not close these gaps. Issue #7 tracks them and the decision whether `req_options` becomes an allowlist: https://github.com/vinnie357/typesafe_sdk_ex/issues/7
    - An unknown key (`[bogus: 1]`) makes `new/1` raise `ArgumentError`.
    - `http_errors: :raise` makes calls raise `RuntimeError`.
    - `url: "http://u:p@host"` and `aws_sigv4:` replace the bearer `authorization` header. Decision 12 promises protection for `default_headers` and per-call `headers` only.
    - `finch: [name: Req.Finch, pool_size: 2]` and the deprecated `finch: :name` raise on the first call.
    - A host application's `config :req, default_options: [finch: [receive_timeout: ...]]` merges under `req_options` and overrides the SDK timeout.

### Headers

11. Precedence, lowest to highest: `default_headers`, per-call `headers`, protected SDK headers (`client.ts:333,353`). Names match case-insensitively. A `nil` value deletes the header.
12. The SDK sets these protected headers on every attempt, and a caller cannot override them through `default_headers` or `headers`:

    | Header | Value |
    |---|---|
    | `authorization` | `Bearer <api_key>` |
    | `accept` | `application/json` |
    | `user-agent` | `typesafe-sdk-ex/<version>` |
    | `x-typesafe-sdk` | `typesafe-sdk-ex/<version>` |
    | `x-typesafe-runtime` | `elixir/<System.version()> (otp/<release>)`, for example `elixir/1.19.5 (otp/28)` |
    | `content-type` | `application/json`, only on a request with a body. The SDK removes a caller's value on GET. |
    | `x-typesafe-retry-count` | Absent on attempt 0, then `"1"`, `"2"`, and so on. The SDK removes a caller's value on every attempt. |

13. The header surface is a one-value-per-name map. A value is a binary, an atom, a number, or `nil`. The SDK converts atoms and numbers with `to_string/1`. A list value is rejected. The `headers` and `default_headers` containers must be maps.
14. The SDK sends no idempotency header and no `x-should-retry` header. The JS SDK sends none either.
15. The SDK reads three response headers: `x-typesafe-request-id`, `retry-after-ms`, and `retry-after`.

### Body decoding

16. The SDK encodes request bodies with Req's `:json` option.
17. The SDK decodes responses itself with `JSON.decode/1`. An empty body decodes to `nil`. A body that is not JSON stays as text. Content-type does not matter (`client.ts:472-489`, `test/errors.test.ts:127-133`).
18. A non-binary body that a custom adapter returns passes through unchanged.
19. A JSON `null` body decodes to `nil`, the same as an empty body.

## Consequences

### Positive

- A caller cannot make the reported timeout differ from the applied timeout through a documented `req_options` route. The property-style test and a 30,000-input fuzz found zero overrides (https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902726637).
- Composition by `base ++ overrides` keeps working.
- JSON without a content-type decodes, as in JS.

### Negative

- `req_options` promises less than its docs imply until issue #7 closes. Two of the gaps contradict the words "never overwrite" in `TypeSafe.HTTP.new_client_req/3` and "never raises" in `TypeSafe.new/1`.
- The SDK owns the denylist. A new Req option that overrides an SDK setting passes until someone adds it.
- Decision 12 deviates from JS values: JS sends `typesafe-sdk/<VERSION>` for both identity headers and `node/22.1.0 (darwin; arm64)`-style runtime strings (`client.ts:352-367`, `src/runtime.ts:21-31`). The Elixir values are the SDK's choice. Whether the server parses these headers is unverified.
- A JSON `null` error body reads as "no body" (ADR 0006), and a `null` success body returns `{:ok, nil}`.
- A caller who needs repeated header names must use `req_options` directly, subject to decisions 1 to 10.

## Alternatives considered

- **Force every SDK-owned option silently, including `receive_timeout`.** Rejected for timeouts: a silent no-op misleads a caller into thinking a timeout took effect. The first PR #6 review round made the same case for `finch:` timeouts.
- **Strip `receive_timeout` from `finch:` at request time.** Rejected: it turns a documented rejection into a silent drop and couples the SDK to Req.Finch's private option list.
- **Reject duplicated keys in `req_options`.** Rejected: it breaks `base ++ overrides` composition, which Req supports with last-wins.
- **Validate the first occurrence only (`Keyword.get/2`).** Rejected after two review rounds: `[finch: [pool_size: 2], finch: [receive_timeout: 5]]` passed and overrode the timeout.
- **An allowlist of supported `req_options` keys.** Deferred to issue #7.
- **Accept Req's list-valued headers.** Rejected by operator decision: the SDK's surface stays a simple map (PR #1 review round 2, R3).
- **Use Req's default JSON decoder.** Rejected: it needs a content-type, so `decode_body: false` plus stdlib `JSON` is required.

## References

- JS: `src/client.ts:166-178` (header merge), `src/client.ts:333,353` (precedence), `src/types.ts:205` (per-call `headers`), `src/api-promise.ts:1-4` (the request-id header), `src/client.ts:352-367` (protected headers), `src/client.ts:360,366-367` (retry count), `src/client.ts:472-489` (body parse), `test/release-regressions.test.ts:15-58` (protected headers on every attempt), `test/release-regressions.test.ts:60-70` (GET strips content-type and retry count), `test/client.test.ts:149-162`, `test/errors.test.ts:127-133`, `src/runtime.ts:21-31`.
- Req 0.7.4: `lib/req/steps.ex:1163-1176` (default decoders), `lib/req/steps.ex:489-492` (`:json`), `lib/req/steps.ex:1748-1753` and `1810-1811` (retry keys the SDK owns), `lib/req.ex:550-552`, `lib/req.ex:590-598`, `lib/req/finch.ex:237-240`, `lib/req/finch.ex:546-548`, `lib/req.ex:425` (`connect_options` starts a dedicated Finch pool).
- PR #1 review round 1, findings N8 and N12: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5714770534
- PR #1 review round 2, findings R2 and R3: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5715301129
- PR #1 review round 3, finding D3: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5722393470
- PR #6 first review, findings B2, N2, N3: https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902350367
- PR #6 second review, finding B1 and observation N1: https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902451018
- PR #6 non-convergence plan: https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902505551
- PR #6 operator decision A′ and the follow-up: https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902546521
- PR #6 re-attestation with the fuzz summary: https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902726637
- Open gaps: https://github.com/vinnie357/typesafe_sdk_ex/issues/7
