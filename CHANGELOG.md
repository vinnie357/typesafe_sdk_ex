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

### Known limitations

- Retries, per-attempt timeouts, the full HTTP error taxonomy, and structured
  logging are not implemented yet. Any non-2xx response currently returns a
  generic `TypeSafe.Error`.
