# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
