# ADR 0007: Retry policy and engine on Req's `:retry`

**Status:** Accepted
**Date:** 2026-09-29; the struct, defaults, and `inspect` rendering date from 2026-09-17

## Context

The JS SDK retries in a hand-written loop with a policy object (`src/retry.ts`, `src/client.ts:350-470`). Req has its own `:retry` step. Req's default, `:safe_transient`, retries only GET and HEAD on 408, 429, 500, 502, 503, and 504 (`req@0.7.4 lib/req/steps.ex:1670-1680,1720-1722,1775`), so a POST is never retried and 5xx coverage is incomplete. Req's own Retry-After handling covers only 429 and 503, reads only `retry-after`, and has no ceiling (`steps.ex:1824-1840`, `lib/req/response.ex` `get_retry_after/1`).

Left on, that default retried a `GET /v1/models` 503 four times over about 6.7 seconds in the first PR review (PR #1 review, B2).

## Decision

### Policy

1. `%TypeSafe.RetryPolicy{}` has nine fields with these defaults, which equal the JS defaults (`retry.ts:11-23`) except `api_timeout_error` (ADR 0008):

   | Field | Default |
   |---|---|
   | `max_retries` | `2` |
   | `backoff_initial_ms` | `500` |
   | `backoff_max_ms` | `5000` |
   | `backoff_jitter` | `0.25` |
   | `http_statuses` | `MapSet` of 408, 429, and 500..599 |
   | `respect_retry_after` | `true` |
   | `max_retry_after_ms` | `60_000` |
   | `api_connection_error` | `true` |
   | `api_timeout_error` | `false` |

2. `retry:` is a keyword list of overrides. `new/1` resolves it into `client.retry`. A per-call `retry:` on `system_one/3` and `list_models/2` merges field by field onto the client policy for that call and leaves `client.retry` unchanged (`client.ts:337`).
3. `TypeSafe.RetryPolicy.merge/2` validates the overrides and never raises. The SDK validates a per-call `retry:` before it sends a request. `merge/2` rejects, with a message that names the problem:
   - a non-keyword value, including `nil`: `"retry must be a keyword list, got nil"`
   - a key given more than once: `"retry.max_retries given more than once"`
   - an unknown key: `"retry has unknown option(s): bogus"`
   - an invalid value: `"retry.max_retries must be a non-negative integer, got -1"`
4. The duplicate-key check runs before the unknown-key check, because `Keyword.validate/2` reports a duplicate as unknown.
5. `max_retries`, `backoff_initial_ms`, `backoff_max_ms`, and `max_retry_after_ms` are non-negative integers. `backoff_jitter` is a number from 0 to 1. The flags are booleans.
6. `http_statuses` is a list, `Range`, or `MapSet` of integers from 100 to 999. The SDK stores it as a `MapSet`. The SDK bounds-checks a `Range` before it expands it, so a huge range cannot hang validation.
7. The three millisecond fields deviate from JS, which accepts fractional finite numbers (`client.ts:70-84,102-147`). Integer fields keep all delay math in exact integers: the doubling stops at the cap, so no attempt number can raise, and jitter multiplies by the exact rational from `Float.ratio/1` and rounds half away from zero, so a huge value cannot overflow a float. Req accepts only an integer `{:delay, _}` (`steps.ex:1803`).
8. The millisecond fields have no upper bound, which matches JS (it checks only finiteness). `Process.sleep/1` accepts very large values without raising.
9. `inspect/1` of a policy shows all nine fields and renders `http_statuses` as compact ranges built from the actual set, for example `http_statuses: [408, 429, 500..599]`. This also applies to a `%TypeSafe.Client{}`, where the policy is a nested field.

### Engine

10. Retries run through Req's `:retry` with the 2-arity function `&TypeSafe.Retry.decide/2`. It returns `{:delay, ms}` or `false` (`steps.ex:1682-1690`).
11. Each call wires the engine: `Req.request(req, retry: &decide/2, max_retries: policy.max_retries, retry_log_level: false, receive_timeout: timeout)`. The effective policy travels in `request.private[:typesafe_retry_policy]`.
12. `client.req` itself keeps `retry: false`, so Req's default retry never runs.
13. The SDK does not use `:retry_delay` or `:safe_transient`. A `:retry_delay` function receives only the retry count (`steps.ex:1693-1700`), so it cannot read `retry-after-ms` or apply the ceiling. Once `:retry_delay` is set, Req skips Retry-After entirely (`steps.ex:1826-1828`). Setting it together with `{:delay, _}` raises `ArgumentError` (`steps.ex:1748-1753`).
14. `decide/2` returns `false` for any 2xx response, even when `http_statuses` lists it.
15. For another response, `decide/2` retries when the status is in `http_statuses`.
16. For an exception, `decide/2` follows `api_timeout_error` when it is `%Req.TransportError{reason: :timeout}`, and `api_connection_error` for any other exception (`client.ts:150-154,383-384`).
17. `decide/2` reads the attempt number from `:req_retry_count` and returns `false` once it reaches `max_retries`. Req still calls the retry function when retries run out (`steps.ex:1808-1813`), so the check is required. After retries run out, the SDK returns the last error.
18. The delay is one of two values. When `respect_retry_after` is set, the response has headers, and the parsed Retry-After is not `nil` and is at most `max_retry_after_ms`, the delay is that value exactly, with no jitter. Otherwise the delay is `round(min(backoff_initial_ms * 2^attempt, backoff_max_ms) * (1 - random * backoff_jitter))`, with `random` in `[0, 1)` (`retry.ts:56-68`). Transport errors have no headers and always use backoff.
19. The ceiling applies on the delay path. `delay_ms/4`, and `decide/2` through it, fall back to backoff when the parsed value exceeds `max_retry_after_ms`. No value handed to Req exceeds `max(max_retry_after_ms, backoff_max_ms)`. The parser itself returns uncapped values (ADR 0009).
20. A request step sets `x-typesafe-retry-count` from Req's private retry counter on every attempt (ADR 0005).
21. The SDK adds no sleep injection, no idempotency key, and no total retry budget. Req calls `Process.sleep/1` directly (`steps.ex:1815`), and a `{:delay, 0}` still calls `Process.sleep(0)`.
22. The SDK does not port the Python retry `exceptions` and `predicate` options. JS rejects them at the type level (`test/types.test-d.ts:132-133`).

## Consequences

### Positive

- POST retries, the full JS status set, `retry-after-ms`, decimals, and a ceiling all work on Req's retry loop, with no second loop to keep in sync.
- The adapter runs inside Req's retry loop, so stubbed tests exercise real Req retries (ADR 0012).
- A policy prints readably in `inspect` output and in a client's `inspect` output.

### Negative

- Three parts are hand-rolled on top of Req: the delay formula (`:retry_delay` cannot express the Retry-After branch), the Retry-After parser (Req reads neither `retry-after-ms`, decimals, nor a ceiling), and the status and flag checks in `decide/2` (Req's `:safe_transient` uses a fixed list).
- `decide/2` is not pure. It calls `:rand.uniform/0` (`retry.ex:103`), and `delay_ms/4` reads `System.os_time/1` to resolve an HTTP-date Retry-After (`retry.ex:53`). Its tests use zero jitter and no HTTP-date header.
- A caller who raises `max_retry_after_ms` far above 60 seconds lets a server's `Retry-After` make one call sleep that long. The README warns about this. No SDK cap exists.
- Integer-only fields reject inputs JS accepts, such as `backoff_initial_ms: 1.5`.

## Alternatives considered

- **Req's `:safe_transient`.** Rejected: it never retries a POST.
- **Req's `:transient`.** Rejected: it retries all methods, but only the fixed status list (408, 429, 500, 502, 503, 504) and with Req's own Retry-After handling, which reads `retry-after` only and has no ceiling (`steps.ex:1670-1680,1775,1824-1840`).
- **A `:retry_delay` function.** Rejected: see decision 13.
- **A hand-written retry loop like JS.** Rejected: the Req step already re-runs request steps and the adapter on each retry (`lib/req/request.ex:1032-1050`), and a second loop would duplicate it.
- **Fractional millisecond fields.** Rejected: see decision 7.

## References

- JS: `src/retry.ts:11-23,56-68`, `src/types.ts:175-194` (the `RetryPolicy` type), `src/client.ts:70-84,102-147,150-154,337,364-400,383-385`, `test/retry.test.ts:38-125`, `test/reliability.test.ts:51-166,195-199,383-421`, `test/types.test-d.ts:132-133`.
- Req 0.7.4: `lib/req/steps.ex:1670-1700,1704,1720-1722,1748-1753,1775,1803-1815,1808-1817,1824-1840`, `lib/req/request.ex:1032-1050`.
- This repository: `lib/type_safe/retry.ex:53,61-66,103` (clock read, exact rounding, jitter), `lib/type_safe/retry_policy.ex`.
- PR #1 review round 1, finding B2 (Req's default retry ran): https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5714770534
- PR #1 review round 3, finding D4 (bracketed `http_statuses` in `inspect`): https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5722393470
- PR #4 review round 2, carried finding (the ceiling belongs in the retry loop): https://github.com/vinnie357/typesafe_sdk_ex/pull/4#issuecomment-5901419967
- PR #5 review, findings N1, N2, N4, N6: https://github.com/vinnie357/typesafe_sdk_ex/pull/5#issuecomment-5901956386
