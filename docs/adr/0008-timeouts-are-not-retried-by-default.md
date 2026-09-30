# ADR 0008: Timeouts are not retried by default

**Status:** Accepted
**Date:** 2026-09-29 (operator decision)

## Context

The JS SDK retries `POST /v1/systemone` on 5xx, 408, 429, connection errors, and timeouts, and it sends no idempotency key (`src/client.ts:321-400`, `test/release-regressions.test.ts:15-58`). The docs say the client SDKs handle 429 and 529 retries automatically (https://docs.typesafe.ai/api.md, "Handling rate limits").

A timed-out `POST /v1/systemone` may already have run and billed by the time the client gives up. No source in the JS repository, its tests, or the docs pages mentions an idempotency key or an `x-should-retry` header. A retry after a timeout can therefore bill twice.

## Decision

1. `api_timeout_error` defaults to `false` for every call, not only POST. JS defaults it to `true` (`retry.ts:22`).
2. A caller opts in with `retry: [api_timeout_error: true]` at `new/1` or per call.
3. The SDK does not split connect timeouts from receive timeouts. Mint reports both as `%Req.TransportError{reason: :timeout}`, so `decide/2` cannot tell them apart. Both follow `api_timeout_error`.
4. Statuses and connection errors keep JS parity, including on POST: 408, 429, and 5xx retry by default, and so do transport failures other than timeouts.
5. The SDK accepts the residual double-billing risk of a connection error that drops mid-response.
6. The opt-outs are `retry: [api_connection_error: false]` for connection errors, and `retry: [max_retries: 0]` for all retries.
7. The SDK invents no idempotency key and sends no idempotency header.

## Consequences

### Positive

- A timeout returns to the caller at once, so a request that may have billed is not resent.
- The safe default needs no per-endpoint logic.

### Negative

- JS users see fewer retries than JS gives them. The README documents the difference and both opt-outs.
- A connect timeout cannot have billed, yet the default does not retry it either. Retrying one needs the same opt-in, and the opt-in then also retries receive timeouts. The PR #6 review observed a connect timeout retried under `api_timeout_error: true, max_retries: 1`, taking 625 ms with a 300 ms connect timeout.
- Connection errors that drop mid-response still retry by default and can double-bill. Callers who cannot accept that opt out.
- A retried request re-sends the same body with an `x-typesafe-retry-count` header. The SDK gives the server no key to deduplicate on.

## Alternatives considered

- **Keep JS parity (`api_timeout_error: true`).** Rejected by operator decision: double billing on timeout.
- **Default to `false` for POST only.** Not chosen: the operator decision covers every call, so callers learn one rule.
- **Split connect timeouts from receive timeouts and retry connect timeouts.** Rejected by operator decision (PR #5 review, N5): Mint gives one error for both, and the SDK adds no second detection path.
- **Invent an idempotency key.** Rejected: the API defines none, and the SDK does not invent wire behavior.

## References

- JS: `src/retry.ts:22`, `src/client.ts:150-154,321-400`, `test/release-regressions.test.ts:15-58`.
- Docs: https://docs.typesafe.ai/api.md ("Handling rate limits", `api.md:L338`).
- PR #5 body (operator decision 2026-09-29): https://github.com/vinnie357/typesafe_sdk_ex/pull/5
- PR #5 review, finding N5 (connect timeouts): https://github.com/vinnie357/typesafe_sdk_ex/pull/5#issuecomment-5901956386
- PR #6 review (connect timeout observation): https://github.com/vinnie357/typesafe_sdk_ex/pull/6#issuecomment-5902350367
