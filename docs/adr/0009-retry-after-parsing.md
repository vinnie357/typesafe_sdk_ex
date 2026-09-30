# ADR 0009: Retry-After parsing

**Status:** Accepted
**Date:** 2026-09-29

## Context

The server tells the client how long to wait through `retry-after-ms` and `Retry-After`. The JS SDK reads both, prefers `retry-after-ms`, and parses with `Number()` and `Date.parse()` (`src/retry.ts:38-49`). `Number()` accepts inputs that are unsafe here: `Number("")` is 0, which would mean an immediate retry against a rate-limiting server, and `Number()` also accepts `"0x10"`, `"1e3"`, and padded whitespace (`retry.ts:39,44`). The header value is untrusted input from a server.

Req cannot supply the parser. Its own handler reads `retry-after` only and covers 429 and 503 (ADR 0007), and its HTTP-date parser lives in `Req.Utils`, which is `@moduledoc false` (`req@0.7.4 lib/req/utils.ex:2`).

## Decision

1. `TypeSafe.Retry.parse_retry_after(headers, now_ms)` returns whole milliseconds as a non-negative integer, or `nil`. It takes `now_ms` as a parameter.
2. `retry-after-ms` wins when it is valid.
3. Otherwise `retry-after` is read, as decimal seconds times 1000 or as an HTTP date.
4. An invalid `retry-after-ms` falls through to `retry-after`.
5. A value is a decimal when it matches `\A(\d+)(?:\.(\d+))?\z` after trimming whitespace (`retry.ex:132`). `""`, `"   "`, `".5"`, `"5."`, `"+5"`, `"1e3"`, and `"0x10"` are not decimals, and a negative number is `nil`. A blank value is `nil`, not 0.
6. The parser rounds half up in exact integer arithmetic, which equals half away from zero for the non-negative values the grammar admits. `retry-after-ms: "2.5"` gives 3, and `"10.4"` gives 10. The parser does not call `Kernel.round/1`, because a float cannot represent oversize digit strings.
7. An HTTP date is whatever `:httpd_util.convert_request_date/1` accepts: RFC 1123, RFC 850, and asctime, the forms RFC 9110 section 5.6.7 permits. The result is `max(0, date - now)`. The parser ignores a timezone token and assumes UTC. Any other value is `nil`.
8. When a header carries several values, the parser uses the first. The parser also reads the first `retry-after-ms` value only.
9. The parser returns uncapped values. A year-9999 date parses to about 2.5e14 ms, and 309 digits parse to an exact 309-digit integer. The ceiling applies on the delay path (ADR 0007).
10. The parser never raises. It reads bytes with `:binary.bin_to_list/1`, so a non-UTF-8 value cannot raise. It rescues the `FunctionClauseError` that `:httpd_util.convert_request_date/1` raises on short inputs and returns `nil`.
11. `TypeSafe.Error.RateLimit.retry_after_ms` uses the same parser (`errors.ts:92-95`).
12. The SDK adds no header-size cap. Mint bounds the response header section before the parser sees it.

## Consequences

### Positive

- A hostile or malformed header cannot raise out of the SDK or trigger an immediate retry loop. A 429 always returns `{:error, %TypeSafe.Error.RateLimit{}}` (PR #4 review, B1).
- The parser is pure. Tests pass `now_ms` and need no clock.

### Negative

- Decisions 5, 6, and 8 deviate from JS. JS accepts `"0x10"`, `"1e3"`, and whitespace, treats a blank value as 0, returns fractional milliseconds, and comma-joins several header values, so `"2, 9"` gives NaN and then `undefined` (`retry.ts:39,44,46`). The port returns `nil` for those three forms and for a blank value, rounds to an integer, and returns 2000 for the two separate values `["2", "9"]`.
- The grammar is unbounded. A hostile 1,000,000-digit value cost about 181 ms of parse time in an observation on 2026-09-29 (Elixir 1.19.5), and 262,000 digits cost about 21 ms. The 256 KiB Mint limit caps the input at just under 262,144 bytes, so the worst input that reaches the parser costs about 21 ms.
- The cap depends on Mint 1.9.2 or later, when `:max_header_list_size` arrived (`deps/mint/lib/mint/http1.ex:170`). Finch 0.24.0 does not override the option. The v0.2.0 README audit re-checks the citations against the locked Mint (issue #8).
- The parser depends on `:inets` being bundled (ADR 0002) and rescues one exception from a function that raises rather than returning an error tuple. Replace it with a hand-written date parser if `:inets` is ever dropped.
- A timezone token is dropped, so `"... PST"` and `"... +0500"` read as UTC. Servers send GMT (RFC 9110).

## Alternatives considered

- **Port `Number()` semantics exactly.** Rejected by lead decisions on the parser: a blank value must not mean an immediate retry, and hex and exponent forms have no place in a delay header.
- **Round with `Kernel.round/1`.** Rejected: floats overflow or raise on oversize digit strings.
- **Cap the parser's result.** Rejected: the ceiling belongs in the retry loop, where `max_retry_after_ms` lives (PR #4 review round 2, carried finding).
- **Cap the header length in the SDK.** Rejected: Mint already bounds it (PR #4 review round 2, N-a).
- **Use `Req.Utils` for dates.** Rejected: it is private API.
- **Parse the timezone token.** Not chosen: `:httpd_util` ignores it and RFC 9110 dates are GMT.

## References

- JS: `src/retry.ts:38-49` (parser), `src/retry.ts:39,44,46`, `src/errors.ts:92-95`, `test/retry.test.ts:54-77`, `test/reliability.test.ts:537-554`.
- Mint 1.11.0 (`mix.lock`): `lib/mint/http1.ex:33` (256 KiB default), `lib/mint/http1.ex:167-170` (option scope, "Available since 1.9.2"), `lib/mint/http1.ex:1081-1088` (`{:max_header_list_size_exceeded, size, max_size}`), `lib/mint/http2.ex:163,1224` (the same default for HTTP/2).
- Req 0.7.4: `lib/req/utils.ex:2`.
- PR #1 review round 3, finding D2 (the pre-split parser read integer seconds only): https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5722393470
- PR #4 review round 1, findings B1, N1, N2, N3: https://github.com/vinnie357/typesafe_sdk_ex/pull/4#issuecomment-5901344671
- PR #4 review round 2, findings N-a, N-b, and the carried finding: https://github.com/vinnie357/typesafe_sdk_ex/pull/4#issuecomment-5901419967
- The README audit that re-checks the Mint citation: https://github.com/vinnie357/typesafe_sdk_ex/issues/8
