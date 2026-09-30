# ADR 0010: Per-attempt timeout on Req `receive_timeout`

**Status:** Accepted
**Date:** 2026-09-17 (a fixed 10 s timeout reaches Req); 2026-09-29 (the `timeout:` option, its bound, and the connect and trickle semantics)

## Context

The JS SDK bounds each attempt, headers plus the full body, with one timer and an `AbortController` (`src/client.ts:403-447`). It accepts any positive finite number of milliseconds (`client.ts:77-84`) and has no total budget across retries (`src/types.ts:200`). The Python SDK adds a 30 s total budget (https://docs.typesafe.ai/sdk/python/api/retries.md, `RetryPolicy.timeout`).

Req has no attempt-level timer. Its `receive_timeout` bounds each socket read (`req@0.7.4 lib/req.ex:445`). Finch applies its own 5,000 ms connect default (`finch@0.24.0 lib/finch.ex:16`).

## Decision

1. `timeout:` is a positive integer number of milliseconds at `new/1` and per call on `system_one/3` and `list_models/2`. The default is `10_000` (`retry.ts:5`).
2. The largest accepted value is `4_294_967_295` (2^32 - 1, about 49.7 days). `:gen_tcp.recv/3` encodes its timeout in 32 bits, and a larger value would wrap. A larger integer returns `"timeout must be at most 4294967295 ms, got <n>"`.
3. `new/1` and the per-call option reject floats, `nil`, and non-numbers with `"timeout must be a positive integer, got <inspect(value, charlists: :as_lists)>"`. The SDK does this before it sends a request.
4. A per-call `timeout: nil` is rejected, not read as "not given". `timeout` has no environment fallback.
5. The effective value is the per-call `timeout:`, else the client's, else `10_000`. A per-call value never changes `client.timeout`.
6. The effective value maps to Req's `receive_timeout` on every attempt. Each retry gets a fresh timeout. There is no total budget, which follows JS.
7. `receive_timeout` bounds each socket read, not the whole response. A server that trickles its body can exceed the timeout. The port accepts this and adds no `Task`-bounded attempt.
8. `TypeSafe.Error.Timeout.timeout_ms` reports the configured per-read value, not elapsed time. `message` is `"Request timed out after <timeout_ms>ms."`.
9. `timeout:` does not bound connecting. The connect phase uses Finch's 5,000 ms default. A caller changes it with `req_options: [connect_options: [timeout: ms]]`. A connect timeout still returns `Timeout`, and its `timeout_ms` is the receive value.
10. `req_options` cannot set the timeout (ADR 0005), so the applied value and the reported value cannot differ.
11. The SDK does not set a top-level `pool_timeout`. Req 0.7.4 deprecates it in favor of `finch: [pool_timeout: ms]` (`lib/req.ex:550-552`). The JS SDK has no pool concept, so Req's pool default stays.
12. The SDK does not port JS `bufferResponse` (`client.ts:180-201`). Req and Finch read the full body.

## Consequences

### Positive

- One number controls each read on every attempt, and a caller sees it in the error.
- The bound prevents a silent wrap to a near-zero timeout.
- A timed-out call leaves the client usable. Mint 1.11 keeps a timed-out connection open and, with Finch 0.23.x, returned it to the pool, so the next request received the stale response and raised. Finch 0.24.0 closes the connection first (PR #3 review). A real-socket test guards the pair (ADR 0012).

### Negative

- Decisions 1, 2, 7, and 9 deviate from JS. JS accepts fractional milliseconds, has no upper bound, and bounds the whole attempt including the body and connecting.
- The PR #6 review measured the semantics. A response that trickled one byte per 40 ms with `timeout: 100` returned `{:ok, []}` after 533 ms. A blackholed connect with `timeout: 200` returned after 5,001 ms with `timeout_ms: 200`. With `connect_options: [timeout: 300]` it returned after 302 ms and still reported 200.
- `timeout_ms` for a connect timeout is a number that did not fire. The docs state this.
- Req's `:connect_options` documentation says 30_000 for the connect default, which is Mint's default. Finch's pool applies 5,000 ms (`finch@0.24.0 lib/finch.ex:16`), and the review measured 5,001 ms. Other routes also set the connect timeout: with `connect_options: [timeout: 300, transport_opts: [timeout: 30]]`, `transport_opts` won (34 ms) in the second PR #6 review. This ADR names the primary route only.
- The bound caps a valid caller at about 49.7 days.
- No total budget means a call with retries can take about `max_retries + 1` times the timeout plus backoff.

## Alternatives considered

- **A `Task.await`-bounded attempt for whole-response semantics.** Rejected on 2026-09-29: it adds a process per call and diverges from Req's model, so the port keeps per-receive semantics and documents the trickle case.
- **A Python-style total budget.** Rejected: JS has none, and the port follows JS (ADR 0001).
- **Split connect and receive timeouts in the error.** Rejected by operator decision (ADR 0008).
- **Accept fractional milliseconds.** Not chosen: it is unverified whether Req's `receive_timeout` accepts a float.
- **Set `timeout` through `req_options`.** Rejected: ADR 0005.

## References

- JS: `src/client.ts:77-84` (positive number check), `src/client.ts:180-201` (`bufferResponse`), `src/client.ts:335-336` (per-call value), `src/client.ts:403-447` (the attempt), `src/retry.ts:5`, `src/types.ts:200`, `test/reliability.test.ts:445-505,524-534`.
- Req 0.7.4: `lib/req.ex:445`, `lib/req.ex:550-552`, `lib/req.ex:425`, `lib/req/finch.ex:237-240`.
- Finch 0.24.0: `lib/finch.ex:16` (`@default_connect_timeout 5_000`).
- Mint 1.11.0: `lib/mint/http1.ex:615` (a receive timeout no longer closes the connection).
- PR #1 review round 1, finding N2 (`client.timeout` never reached Req): https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5714770534
- PR #3 review findings 1 and 5, and re-attestation: https://github.com/vinnie357/typesafe_sdk_ex/pull/3#issuecomment-5900903615, https://github.com/vinnie357/typesafe_sdk_ex/pull/3#issuecomment-5901000229
- PR #6 first review, findings B1 and N1, and probes: https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902350367
- PR #6 second review, observation N2 (other connect-timeout routes): https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902451018
- Python budget: https://docs.typesafe.ai/sdk/python/api/retries.md (`retries.md:L428-L430`)
