# ADR 0012: Test seams without mocking libraries

**Status:** Accepted
**Date:** 2026-09-17; amended 2026-09-29 (the real-socket test); amended 2026-09-30 (`config :req, :default_options` test module); amended 2026-09-30 (telemetry test seams, issue #13)

## Context

The JS suite injects a `mockFetch` and fake timers (`test/helpers.ts:10-21`, `test/reliability.test.ts:43`). The port has no `plug`, `Req.Test`, or Mox (ADR 0002), and the test output must stay clean: a suite that prints Req's deprecation warnings fails the clean-output rule. Retry tests must not sleep.

## Decision

1. Tests stub HTTP with `TypeSafe.StubAdapter`, a Req module adapter in `test/support/stub_adapter.ex`, compiled through `elixirc_paths(:test)`. `run/1` reads a closure from `request.private[:typesafe_stub]` and calls it.
2. The adapter is a module, not a function. Req 0.7.4 prints a deprecation warning on stderr for every function adapter: "setting `adapter` to a function is deprecated in favour of setting it to a module" (`req@0.7.4 lib/req/request.ex:1066-1069`).
3. Tests do not use `Req.Test`, plug, or Mox.
4. The closure lives in the request's private map. No global or process-dictionary state exists, so the stub is safe under `async: true`, and it survives retries, which reuse the same request struct (`lib/req/steps.ex:1816-1817`).
5. A stub returns `{request, %Req.Response{}}`, or `{request, %Req.TransportError{reason: reason}}` for a transport failure. A stateful sequence such as `[503, 503, 200]` comes from an `Agent` started with `start_supervised`. A stub reports each request to the test process with `send/2`, and tests use `assert_received` and `refute_received`.
6. The adapter runs inside Req's retry loop, so stubbed tests exercise real Req retries. The adapter runs at the end of `run_request` (`lib/req/request.ex:1052-1063`). A response flows to the response steps, where `retry` runs first (`lib/req/steps.ex:87`). An exception flows to the error steps (`lib/req/request.ex:1090-1105`), which also start with `retry` (`lib/req/steps.ex:95`). Req then calls `run_request/1` again (`lib/req/steps.ex:1817`), which re-runs the request steps and the adapter.
7. Tests inject the environment through `new(get_env: fn name -> Map.get(env, name) end)`. They never call `System.put_env`. They do not call `Application.put_env` either, with one exception (a second `async: false` module is in decision 14): Req reads `config :req, :default_options` from the application env and has no per-call injection, so `test/typesafe/req_default_options_test.exs` sets it. That module is `async: false`, saves the previous value in `setup`, and restores it in `on_exit` (ADR 0005 decision 10).
8. `TypeSafe.Retry.delay_ms/4` and `TypeSafe.Retry.parse_retry_after/2` are pure. Tests pass the clock and the random function. `decide/2` is not pure (ADR 0007), so its tests use zero jitter and no HTTP-date header.
9. End-to-end retry tests use zero delay: `retry: [backoff_initial_ms: 0, backoff_max_ms: 0]`, `retry-after-ms: 0`, or `respect_retry_after: false` with zero backoff. `Process.sleep(0)` returns at once.
10. The SDK adds no `:sleep` option. Req calls `Process.sleep/1` directly (`lib/req/steps.ex:1815`).
11. One test uses a real socket: a loopback `:gen_tcp` server holds its first response until the test releases it, which the test does once the second call is on the wire, so no wall-clock delay decides the outcome (issue #15). The first call has a short client timeout and times out. The second call on the same client, made with a longer timeout, must return `{:ok, _}` or a clean `{:error, %TypeSafe.Error.*{}}` and never raise. The server is a long-lived acceptor process that owns the listener, binds port 0, and closes the listener in `on_exit`.
12. No test calls the live API, and `mise run ci` needs no API key.
13. Tests observe `:telemetry` events through `TypeSafe.TelemetryForwarder` (`test/support/telemetry_forwarder.ex`). It attaches a handler under a unique id and forwards an event to the test process only when the handler runs in that process, or in a process that lists it in `$callers` (`Task.async/1` does). A handler attached by one test is inert for every other test's processes, so telemetry tests stay `async: true`. Each test detaches its handler in `on_exit`.
14. `test/typesafe/default_logger_test.exs` is `async: false`, for two pieces of state no test can isolate: the handler id `"typesafe-default-logger"` is VM-global, and the global `Logger` level is `:none` in `config/test.exs`, so `capture_log/2` sees nothing until the test raises it. The module restores both in `on_exit`.
15. `TypeSafe.Telemetry.log_lines/3` and `redact_headers/1` are pure: a test passes an event, its measurements, and its metadata and gets the lines, with no `Logger` and no handler involved.

## Consequences

### Positive

- The suite runs against a Req request in every step except the socket, so a Req upgrade that changes retry or step order shows up in tests.
- No mocking library, no global state, and no sleep.

### Negative

- Tests depend on Req internals: `request.private`, the step order, and the adapter contract. A Req change to those breaks the seam. The dependency is pinned to `~> 0.7.4`.
- The stub cannot show a real transport: no TLS, no keep-alive, and no Finch pooling. The single real-socket test covers timeout-then-reuse only.
- No live test proves behavior against the real API. The unverified cases in ADR 0001 and ADR 0011 stay unverified.

## Alternatives considered

- **`Req.Test` with `plug`.** Rejected: `Req.Test.json/2` and `transport_error/2` require `Plug.Conn` (`req@0.7.4 lib/req/test.ex:417-419`), and the `:plug` option routes through the `Req.Plug` adapter (`lib/req.ex:604`). ADR 0002 excludes `plug`.
- **Mox.** Rejected: ADR 0002.
- **A function adapter.** Rejected: decision 2.
- **A `:sleep` option for tests.** Rejected: Req sleeps internally, so the option could not cover the call it replaces. Zero delays already avoid the wait.
- **A single-accept loopback server.** Rejected: it produced a false `:closed` in the PR #3 review, because the listener died with the one connection. The acceptor loop fixes that.
- **Live-API tests in CI.** Rejected: CI has no credentials.

## References

- JS: `test/helpers.ts:10-21`, `test/reliability.test.ts:43`.
- Req 0.7.4: `lib/req/request.ex:1032-1063,1066-1069,1090-1105`, `lib/req/steps.ex:87,95,1815-1817`, `lib/req/test.ex:417-419`, `lib/req.ex:604`.
- `test/support/stub_adapter.ex` and `test/typesafe/timeout_test.exs` (the real-socket test).
- PR #3 review, finding 5 and the discrepancy note: https://github.com/vinnie357/typesafe_sdk_ex/pull/3#issuecomment-5900903615, https://github.com/vinnie357/typesafe_sdk_ex/pull/3#issuecomment-5901000229
