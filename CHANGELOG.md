# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-09-30

### Added

- Retries: requests failing with 408, 429, 5xx, or a connection error are
  retried up to twice with exponential backoff and jitter, honoring
  `Retry-After` and `retry-after-ms` up to `max_retry_after_ms`. The policy is
  set with `retry:` on `TypeSafe.new/1` and overridden, merged field by field,
  per call on `TypeSafe.system_one/3` and `TypeSafe.list_models/2`. Retries send
  an `X-TypeSafe-Retry-Count` header. See `TypeSafe.RetryPolicy`.
- `timeout:` (positive integer milliseconds) on `TypeSafe.new/1` and per call on
  `TypeSafe.system_one/3` and `TypeSafe.list_models/2`. The effective value is
  sent to Req as `receive_timeout` on every attempt and reported by
  `TypeSafe.Error.Timeout`. `nil`, floats, `0`, and negatives are rejected, as
  is a value above 4_294_967_295 ms. `timeout:` bounds each socket read, not
  connecting (Finch's 5_000 ms default, set with
  `req_options: [connect_options: [timeout: ms]]`).

### Fixed

- `TypeSafe.new/1` rejects an explicit blank or whitespace-only `api_key` with
  `TYPESAFE_API_KEY is required.` even when `TYPESAFE_API_KEY` is set; it
  previously fell back to the environment key. `api_key: nil` still falls back.
- `TypeSafe.list_models/2` and `TypeSafe.system_one/3` return
  `{:error, %TypeSafe.Error{}}` (`list_models/2 requires a keyword list of
  options`, `system_one/3 requires a keyword list of options`) for call options
  that are not a keyword list, instead of raising.
- An empty-string `error`, `error.message`, `message`, `detail`, or
  `detail.message` in an error body no longer gives the message `"<status> "`.
  As in the JS SDK, the search stops at that field and the message is
  `"<status> <raw body>"`.
- An error body of JSON `null` gives the message `"<status> null"` instead of
  `"<status> status code (no body)"`; `error.body` is still `nil`.
- The `TypeSafe.Error.Timeout` moduledoc described the timeout as `client.timeout`
  "until a per-call override" lands. It now states the shipped behavior.
- A validation `loc` that holds a JSON object or a nested list no longer raises
  (`Protocol.UndefinedError`, `ArgumentError`) or puts control bytes in the
  message. It renders as in the JS SDK's `join`: an object as `[object Object]`,
  a nested list as its comma join.
- When Finch's pool cannot hand out a connection within `pool_timeout`, the call
  returns `{:error, %TypeSafe.Error.Connection{reason: :pool_timeout}}` instead
  of raising a `RuntimeError`. It is not retried. README section "Connection
  pool" covers sizing with `finch: [size: n]` and `finch: [pool_timeout: ms]`.
- `TypeSafe.system_one/3` returns `{:error, %TypeSafe.Error{message:
  "system_one/3 request cannot be encoded as JSON"}}`, and sends nothing, when
  the request holds a PID, a tuple, a struct without an encoder, a tuple map
  key, or invalid UTF-8, instead of raising. Malformed Elixir data still raises:
  an improper list (`FunctionClauseError`), a charlist map key holding an
  invalid code point (`UnicodeConversionError`), and an improper-list map key
  (`ArgumentError`). The message never includes the content.
- `TypeSafe.new/1` trims U+FEFF (the byte order mark) like whitespace, for
  `api_key` and every environment value, as JS `trim` does. A BOM-only value is
  blank, and a BOM around a key is no longer sent in the `authorization` header.
- A repeated option key in `TypeSafe.new/1`, `TypeSafe.system_one/3`, or
  `TypeSafe.list_models/2` returns `<key> given more than once` instead of
  `Unknown option(s): <key>`.
- `TypeSafe.new/1` and calls no longer raise, or send what the SDK did not
  intend, for these `req_options`, each now an `{:error, %TypeSafe.Error{}}` from
  `new/1`:
  - `http_errors: :raise` made a non-2xx response raise `RuntimeError`.
  - `url: "http://user:pass@host"` and `aws_sigv4:` replaced the bearer
    `authorization` header.
  - `redirect_trusted: true` sent the bearer key to a redirect host.
  - `json:` replaced the SDK's request body.
  - An invalid `plugins:` entry such as `[:x]`, an unknown key, and a
    `headers:` value Req cannot encode raised in `Req.new/1`. A valid plugin
    function built a client and ran caller code on the request.
  - `finch: [name: Req.Finch, pool_size: 2]` and `finch: [pool_size: 2]` raised
    on the first call; `pool_size` is not a Finch key (use `size`).
  - `finch: :unregistered_name` raised on the first call.
  - An `auth` in `config :req, :default_options` no longer reaches the request,
    and a `finch: [receive_timeout: ...]` there no longer overrides `timeout:`.
  A `finch: [name: X]` for a pool nobody started, and a wrong-typed value such
  as `finch: [size: :x]`, still raise on the first call.

### Changed

- `TypeSafe.noul/2` raises `FunctionClauseError` for `criteria` that is neither
  a map nor `nil`, like `choice/2` and `score/2`; it previously returned a map
  carrying the value.
- A `retry:` list that repeats a key is rejected with
  `retry.<key> given more than once` instead of `retry has unknown option(s)`.
- Timeouts are not retried by default (`api_timeout_error: false`), unlike the
  JS SDK: a timed-out `POST /v1/systemone` may already have been processed and
  billed. Opt in with `retry: [api_timeout_error: true]`.
- `req_options` now rejects `retry_delay`, `max_retries`, and `retry_log_level`,
  naming the option, and rejects `request_timeout` and `finch: [receive_timeout:
  ...]` / `finch: [request_timeout: ...]`, which would override `timeout:`.
  `finch:` together with `connect_options:` is rejected at `new/1` instead of
  raising on the first request. Use `finch: [pool_timeout: ms]` rather than the
  deprecated top-level `pool_timeout`.
  These checks judge the last of a repeated key, the value Req keeps for a
  non-`headers:` key, so `[finch: [size: 2], finch: [receive_timeout: 5]]`
  is rejected and `[finch: [receive_timeout: 5], finch: [size: 2]]` is
  not.
- **Breaking:** `req_options` is a transport allowlist. `new/1` accepts only
  `adapter`, `connect_options`, `finch`, `finch_private`, `headers`, `inet6`,
  and `unix_socket`, plus `base_url`, `decode_body`, `retry`, and `auth`, which
  the SDK overrides. `finch:` takes only `name`, `pool_timeout`, `pool_tag`,
  `size`, `count`, `protocols`, `conn_opts`, `pool_max_idle_time`,
  `conn_max_idle_time`, `start_pool_metrics?`, and `http2`; `connect_options:`
  takes only `timeout`, `protocols`, `transport_opts`, `proxy`,
  `proxy_headers`, `hostname`, and `client_settings`. Keys are checked, not
  values. `new/1` now returns `{:error, %TypeSafe.Error{}}` for input it used
  to accept:
  - any other key, such as `params`, `redirect`, `http_errors`, `url`, `json`,
    `body`, `plug`, or `plugins`, and a top-level `pool_timeout`, `size`, or
    `pool_size`;
  - `finch:` as a pool name atom (write `finch: [name: pool]`) or as a
    non-keyword value, a `connect_options:` that is not a keyword list, and
    `finch: [name: ..., <pool option>: ...]`, where the pool options are every
    `finch:` key except `name`, `pool_timeout`, and `pool_tag`;
  - `headers:` that is not a map or a list of `{name, value}` pairs with a
    binary or atom name and a binary or list-of-binaries value. An integer or
    `DateTime` value, such as `headers: [{"x-n", 1}]`, worked before and is
    rejected now.
  A repeated `headers:` in `req_options` changed meaning: Req folded the
  entries, and now only the last one is kept.
  The same allowlist checks `config :req, :default_options`, merged under
  `req_options` as Req merges it, and an error names that config as its source
  when the offending key is not in `req_options`. When `req_options` sets no
  `headers:`, every `headers:` entry in the config is checked. A `finch:` and a
  `connect_options:` from different sources give an error that names both. The
  config is read when `new/1` runs.
- `TypeSafe.Error.RateLimit.retry_after_ms` now parses `retry-after-ms`,
  decimal-seconds `Retry-After` values, and HTTP dates (IMF-fixdate, RFC 850,
  asctime), rounded to whole milliseconds; previously only integer seconds
  were read. `:inets` is now a declared application, so consuming apps start it
  (adds `inets_sup` and `httpc_manager`).

## [0.1.1] - 2026-09-29

### Security

- Update transitive dependencies Mint to 1.11.0 (fixes CVE-2026-91043,
  CVE-2026-92103, and CVE-2026-94194; CVE-2026-82672 was fixed in 1.10.1),
  Finch to 0.24.0, and hpax 1.0.4 → 1.1.0 (required by Mint 1.11). Apps
  depending on this library resolve these in their own mix.lock and should run
  `mix deps.update mint finch`. Safe combinations: Mint 1.10.x at 1.10.2 or
  later with any Finch, or Mint 1.11.x with Finch 0.24.0 or later (Mint 1.11.0
  with Finch 0.23.x can raise on the request after a receive timeout).

## [0.1.0] - 2026-09-17

### Added

- `TypeSafe.new/1` client construction with `api_key:`, `base_url:`,
  `default_model:`, and `log_level:` options resolving through `TYPESAFE_*`
  environment variables.
- `TypeSafe.system_one/3` to ask typed questions about application state.
- `TypeSafe.list_models/2` to list available models.
- Question builders `TypeSafe.noul/0`, `TypeSafe.noul/1`, `TypeSafe.noul/2`,
  `TypeSafe.choice/2`, and `TypeSafe.score/2`.
- Status-mapped error taxonomy for `TypeSafe.system_one/3` and
  `TypeSafe.list_models/2`: `TypeSafe.Error.BadRequest`,
  `TypeSafe.Error.Authentication`, `TypeSafe.Error.PermissionDenied`,
  `TypeSafe.Error.NotFound`, `TypeSafe.Error.UnprocessableEntity`,
  `TypeSafe.Error.RateLimit` (with `retry_after_ms`),
  `TypeSafe.Error.InternalServer`, and a catch-all `TypeSafe.Error.API` for
  any other non-2xx status. Every one of these carries `status`, `body`
  (decoded JSON, text, or `nil`), `headers`, `request_id`, and `message`.
  Message text is extracted from the response body per a fixed set of
  rules (`error`/`message`/`detail` shapes), falling back to the raw body
  text truncated to 200 characters.
- Transport-failure errors `TypeSafe.Error.Timeout` (the configured timeout
  was exceeded) and `TypeSafe.Error.Connection` (any other transport
  failure), replacing the earlier placeholder error for every non-2xx
  response and transport failure.

### Known limitations

- Retries, per-attempt timeouts, and structured logging are not implemented
  yet.
