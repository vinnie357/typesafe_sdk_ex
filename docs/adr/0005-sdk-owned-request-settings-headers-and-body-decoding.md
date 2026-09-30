# ADR 0005: SDK-owned request settings, headers, and body decoding

**Status:** Accepted
**Date:** 2026-09-17; amended 2026-09-29 (retry keys, timeout keys, last-wins resolution); amended 2026-09-30 (transport allowlist, `config :req, :default_options`, header shape; issue #7)

## Context

The JS SDK takes a `fetch` option and builds its headers in one place (`src/client.ts:352-367`). The port maps `fetch` to `req_options`, a keyword list merged into `Req.new/1`. That list is a caller's escape hatch, and left open it reaches settings the SDK depends on: the base URL, the bearer header, the request body, body decoding, retries, and timeouts. A silent override breaks the SDK's own guarantees. For timeouts it makes `TypeSafe.Error.Timeout.timeout_ms` report a number that never fired (ADR 0010).

Req decodes bodies by content-type (`req@0.7.4 lib/req/steps.ex:1163-1176`), so it cannot parse JSON that arrives without one. JS parses JSON whatever the content-type (`client.ts:472-489`).

## Decision

### `req_options`

1. `TypeSafe.new/1` validates `req_options` (decisions 2 to 10), then passes the deduplicated, last-wins list to `Req.new/1` and forces `base_url` to the client's and `decode_body: false` and `retry: false`. The SDK overrides a caller's value for these three without an error. The SDK drops a caller's `:auth` and sets the `authorization` header itself. `Req.new/1` also merges `config :req, :default_options`, which can carry an `:auth`, so the SDK removes `:auth` from the built request as well, and `client.req.options` never holds one.
2. `new/1` rejects these keys with `{:error, %TypeSafe.Error{}}` that names the key: `receive_timeout`, `request_timeout`, `retry_delay`, `max_retries`, and `retry_log_level`.
3. `new/1` rejects `finch: [receive_timeout: _]` and `finch: [request_timeout: _]`. Req merges `finch:` request options over the top-level ones (`req@0.7.4 lib/req/finch.ex:237-240`).
4. `new/1` rejects `finch:` together with `connect_options:`. Req raises `ArgumentError` for the pair on the first request (`lib/req/finch.ex:546-548`).
5. `new/1` rejects a `req_options` value that is not a keyword list, a `finch:` value that is not a keyword list (an atom pool name, the form Req deprecates, is rejected: it raises on the first call when no such pool runs), and a `connect_options:` value that is not a keyword list (it raises on the first request).
6. `req_options` is a transport allowlist. `new/1` accepts these top-level keys: `adapter`, `connect_options`, `finch`, `finch_private`, `headers`, `inet6`, and `unix_socket`. It also accepts `base_url`, `decode_body`, `retry`, and `auth`, which the SDK overrides (decision 1). It rejects every other key with `"<source> does not support <key>; supported keys are adapter, connect_options, finch, finch_private, headers, inet6, unix_socket"`. That closes the paths through which a caller could change what the SDK sends or make a call raise: `http_errors: :raise` makes a non-2xx response raise `RuntimeError`; `url: "http://u:p@host"` and `aws_sigv4:` replace the bearer `authorization` header; `redirect_trusted: true` sends the bearer key to a redirect host; `json:` replaces the SDK's request body; an invalid `plugins:` entry such as `[:x]` and an unknown key raise in `Req.new/1` (`UndefinedFunctionError`, `ArgumentError`), while a valid plugin function builds and runs caller code on the request; a header value Req cannot encode raises `Protocol.UndefinedError` there. The same paths, run against Req 0.7.4 on 2026-09-30, produced each of these effects. `plug:` and `body:` are rejected too, as options that can change what the SDK sends.
7. Sub-keys are allowlisted, by key only and not by value. `finch:` takes `name`, `pool_timeout`, `pool_tag`, `size`, `count`, `protocols`, `conn_opts`, `pool_max_idle_time`, `conn_max_idle_time`, `start_pool_metrics?`, and `http2`; any other key is rejected with `"<source> does not support finch: [<key>: ...]"`. `pool_size` is not a Finch 0.24 key, and a client built with it raises `CaseClauseError` on the first call. `connect_options:` takes `timeout`, `protocols`, `transport_opts`, `proxy`, `proxy_headers`, `hostname`, and `client_settings`, with the message `"<source> does not support connect_options: [<key>: ...]"`. A `finch:` that holds `name:` and a pool key other than `pool_timeout` and `pool_tag` is rejected with `"<source> must not set finch: [name: ...] together with finch: [<key>: ...]"`, naming the first such key given; Req raises `ArgumentError` for the pair on the first call (`lib/req/finch.ex:578-583`).
8. `headers:` must be a map or a list of `{name, value}` pairs. A name is a binary or an atom. A value is a binary or a list of binaries, so an integer or a `DateTime` value, which Req stringified before, is rejected; a list value reaches the adapter as several values for that name. Anything else is rejected with `"<source> headers must be a map or a list of {name, value} pairs"`; without the check, `Req.new/1` raises on a bad header (operator decision 2026-09-30). This is Req's header surface, and it differs from the SDK's `default_headers` and per-call `headers` (decision 13).
9. `new/1` checks the view Req resolves: `config :req, :default_options` with `req_options` merged over it. `Req.new/1` and `Req.merge/2` collapse a keyword list with last-wins (`Map.new/1`, `lib/req.ex:590-598`), and `Req.new/1` merges the application config under the options with `Keyword.merge/2` (`lib/req.ex:475`), so a key in `req_options` replaces the config's whole value for it. Every check in decisions 2 to 8 runs on that merged, collapsed view. A duplicate key is judged by the value Req keeps. `[finch: [receive_timeout: 5], finch: [size: 2]]` is accepted. `[finch: [size: 2], finch: [receive_timeout: 5]]` is rejected. `[finch: [name: :p, size: 2], finch: [size: 3]]` is accepted, since the kept `finch:` has no `name:`, and the reverse order is rejected. A benign duplicate such as `[finch: [size: 2], finch: [size: 3]]` is accepted, so `base ++ overrides` composition works. What reaches `Req.new/1` is the collapsed `req_options`, so a repeated `headers:` in `req_options` keeps only its last entry; before this change Req folded them. `Req.new/1` folds every `headers:` entry of `config :req, :default_options` and raises on a bad one, so when `req_options` sets no `headers:`, `new/1` checks each entry in the config; when it does, the config entries are replaced and not checked.
10. `<source>` is `req_options`, or `config :req, :default_options` when the offending top-level key is absent from `req_options`, so a bad application config is not blamed on the caller's list. The `finch:` and `connect_options:` pair error names both, `req_options and config :req, :default_options must not set both finch and connect_options; Req accepts only one of them`, when one key comes from each source. The checks run in this order, and a test pins it: the keyword-list type, the five named keys, the `finch:` shape, the `finch:` timeouts, the `finch:` and `connect_options:` pair, the top-level allowlist, the `finch:` sub-keys, the `finch:` name and pool rule, the `connect_options:` shape, the `connect_options:` sub-keys, and the `headers:` shape. The SDK reads `config :req, :default_options` when `new/1` runs; a later change to it does not reach an existing client. A `finch: [name: X]` that names a pool nobody started raises `ArgumentError` on the first call. That is a documented programming error, like sending to an unstarted process (ADR 0003 decision 6), and not something `new/1` can check.

The invariant is: for every `req_options` and `config :req, :default_options` that `new/1` accepts, the resolved `client.req.options` holds only allowlisted and SDK-owned keys, holds no `:auth`, holds no `:receive_timeout` or `:request_timeout`, holds none of them inside `options[:finch]`, and never holds both `:finch` and `:connect_options`. The request has no `body` and no `into`.

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
14. The SDK adds no header of its own beyond the table above; caller headers follow decision 11. ADR 0008 records the absence of an idempotency header.
15. The SDK reads three response headers: `x-typesafe-request-id`, `retry-after-ms`, and `retry-after`.

### Body decoding

16. The SDK encodes request bodies with Req's `:json` option.
17. The SDK decodes responses itself with `JSON.decode/1`. An empty body decodes to `nil`. A body that is not JSON stays as text. Content-type does not matter (`client.ts:472-489`, `test/errors.test.ts:127-133`).
18. A non-binary body that a custom adapter returns passes through unchanged.
19. A JSON `null` body decodes to `nil`, the same as an empty body.

## Consequences

### Positive

- A caller cannot make the reported timeout differ from the applied timeout through a documented `req_options` route. The property-style test and a 30,000-input fuzz found zero overrides (https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902726637).
- A key that Req adds later is rejected until someone allows it. A test walks `Req.new().registered_options` and requires every key outside the allowlist to be rejected without raising.
- Composition by `base ++ overrides` keeps working.
- JSON without a content-type decodes, as in JS.

### Negative

- A caller who needs a Req option outside the allowlist (`params`, `redirect`, `http_errors`, `plugins`, and the rest) cannot pass it through the client.
- The checks read keys and shapes, not values. A wrong-typed value such as `finch: [size: :x]`, `connect_options: [timeout: :x]`, or `adapter: 5` passes `new/1` and raises on the first call (each observed on 2026-09-30 against `Req` 0.7.4).
- A `finch: [name: X]` for a pool nobody started raises on the first call (decision 10).
- Req has no per-call way to set `config :req, :default_options`, so the tests for decisions 9 and 10 that need it run in one module with `async: false`, which saves and restores the application env (ADR 0012 decision 7).
- Decision 12 deviates from JS values: JS sends `typesafe-sdk/<VERSION>` for both identity headers and `node/22.1.0 (darwin; arm64)`-style runtime strings (`client.ts:352-367`, `src/runtime.ts:21-31`). The Elixir values are the SDK's choice. Whether the server parses these headers is unverified.
- A JSON `null` error body gives the message `"<status> null"` with `body: nil` (ADR 0006 decision 13), and a `null` success body returns `{:ok, nil}`.
- A caller who needs repeated header names uses `req_options: [headers: [...]]`, subject to decisions 1 to 10.

## Alternatives considered

- **Force every SDK-owned option silently, including `receive_timeout`.** Rejected for timeouts: a silent no-op misleads a caller into thinking a timeout took effect. The first PR #6 review round made the same case for `finch:` timeouts.
- **Strip `receive_timeout` from `finch:` at request time.** Rejected: it turns a documented rejection into a silent drop and couples the SDK to Req.Finch's private option list.
- **Reject duplicated keys in `req_options`.** Rejected: it breaks `base ++ overrides` composition, which Req supports with last-wins.
- **Validate the first occurrence only (`Keyword.get/2`).** Rejected after two review rounds: `[finch: [size: 2], finch: [receive_timeout: 5]]` passed and overrode the timeout.
- **An allowlist of supported `req_options` keys.** Adopted for issue #7 (decisions 6 to 8): the denylist left `http_errors`, `url`, `aws_sigv4`, and `redirect_trusted` open.
- **Validate `req_options` alone, not the merged view.** Rejected: `config :req, :default_options` merges under `req_options` and reached the same options (a default `finch: [receive_timeout: 5]` overrode the SDK timeout, and a default `auth` reached Req's `:auth` step).
- **Check values as well as keys.** Rejected by operator decision 2026-09-30: sub-keys are checked by key only.
- **Accept Req's list-valued headers.** Rejected by operator decision: the SDK's surface stays a simple map (PR #1 review round 2, R3).
- **Use Req's default JSON decoder.** Rejected: it needs a content-type, so `decode_body: false` plus stdlib `JSON` is required.

## References

- JS: `src/client.ts:166-178` (header merge), `src/client.ts:333,353` (precedence), `src/types.ts:205` (per-call `headers`), `src/api-promise.ts:1-4` (the request-id header), `src/client.ts:352-367` (protected headers), `src/client.ts:360,366-367` (retry count), `src/client.ts:472-489` (body parse), `test/release-regressions.test.ts:15-58` (protected headers on every attempt), `test/release-regressions.test.ts:60-70` (GET strips content-type and retry count), `test/client.test.ts:149-162`, `test/errors.test.ts:127-133`, `src/runtime.ts:21-31`.
- Req 0.7.4: `lib/req/steps.ex:1163-1176` (default decoders), `lib/req/steps.ex:489-492` (`:json`), `lib/req/steps.ex:1748-1753` and `1810-1811` (retry keys the SDK owns), `lib/req.ex:550-552`, `lib/req.ex:590-598`, `lib/req/finch.ex:237-240`, `lib/req/finch.ex:546-548`, `lib/req/finch.ex:578-583`, `lib/req.ex:475`, `lib/req.ex:425` (`connect_options` starts a dedicated Finch pool).
- PR #1 review round 1, findings N8 and N12: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5714770534
- PR #1 review round 2, findings R2 and R3: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5715301129
- PR #1 review round 3, finding D3: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5722393470
- PR #6 first review, findings B2, N2, N3: https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902350367
- PR #6 second review, finding B1 and observation N1: https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902451018
- PR #6 non-convergence plan: https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902505551
- PR #6 operator decision A′ and the follow-up: https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902546521
- PR #6 re-attestation with the fuzz summary: https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902726637
- Open gaps: https://github.com/vinnie357/typesafe_sdk_ex/issues/7
