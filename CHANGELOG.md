# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Retries: requests failing with 408, 429, 5xx, or a connection error are
  retried up to twice with exponential backoff and jitter, honoring
  `Retry-After` and `retry-after-ms` up to `max_retry_after_ms`. The policy is
  set with `retry:` on `TypeSafe.new/1` and overridden, merged field by field,
  per call on `TypeSafe.system_one/3` and `TypeSafe.list_models/2`. Retries send
  an `X-TypeSafe-Retry-Count` header. See `TypeSafe.RetryPolicy`.

### Changed

- Timeouts are not retried by default (`api_timeout_error: false`), unlike the
  JS SDK: a timed-out `POST /v1/systemone` may already have been processed and
  billed. Opt in with `retry: [api_timeout_error: true]`.
- `req_options` now rejects `retry_delay`, `max_retries`, and `retry_log_level`,
  naming the option.

- `TypeSafe.Error.RateLimit.retry_after_ms` now parses `retry-after-ms`,
  decimal-seconds `Retry-After` values, and HTTP dates (IMF-fixdate, RFC 850,
  asctime), rounded to whole milliseconds; previously only integer seconds
  were read. `:inets` is now a declared application, so consuming apps start it
  (adds `inets_sup` and `httpc_manager`).

## [0.1.1] - 2026-09-29

### Security

- Update transitive dependencies Mint to 1.11.0 (fixes CVE-2026-91043,
  CVE-2026-92103, CVE-2026-94194, CVE-2026-82672), Finch to 0.24.0, and hpax
  1.0.4 → 1.1.0 (required by Mint 1.11). Apps depending on this library resolve
  these in their own mix.lock and should run `mix deps.update mint finch`.
  Safe combinations: Mint >= 1.10.2 with any Finch, or Mint 1.11.x with Finch
  >= 0.24.0 (Mint 1.11.0 with Finch 0.23.x can raise on the request after a
  receive timeout).

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
