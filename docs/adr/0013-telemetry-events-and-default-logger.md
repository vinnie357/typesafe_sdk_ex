# ADR 0013: Telemetry events and an opt-in default logger

**Status:** Accepted
**Date:** 2026-09-30 (issue #13, slice 0); amended 2026-09-30 (known-scheme allowlist and whitespace, issue #22; pool-timeout duration, PR #21; the PR #24 review rounds; E6 supersession for `:debug`, decision 17, issue #13 audit)

## Context

The JS SDK logs through a `Logger` interface: a `logLevel` filter, a default console logger with the `[typesafe-sdk]` prefix, a `logger` option, and credential redaction (`logging.ts:5-79`, `client.ts:276,340-399,431-466`). ADR 0001 listed all of it as not ported, and ADR 0004 recorded that `log_level` had no effect.

An Elixir library does not own a log sink. The BEAM convention is `:telemetry` events that any application can handle, plus `Logger` for the lines a person reads. The operator decisions on issue #13 (2026-09-30, E1 to E7) chose events as the SDK's output and an opt-in default logger that prints the JS log lines from them.

## Decision

### Events

1. The SDK emits three `:telemetry` events. `TypeSafe.Telemetry`'s `@moduledoc` is the catalog, and this ADR does not repeat it field by field:

   | Event | Measurements | Fires |
   |---|---|---|
   | `[:typesafe, :attempt, :start]` | `monotonic_time`, `system_time` (native units) | Before each HTTP attempt, retries included |
   | `[:typesafe, :attempt, :stop]` | `duration`, `monotonic_time` (native units) | When an attempt ends with a response or a transport error |
   | `[:typesafe, :request, :retry]` | `delay_ms` (milliseconds) | After the stop of an attempt the retry policy will repeat, before the delay |

2. Metadata on all three: `request_number`, `method`, `path`, `log_level`, and `attempt` (0 for the first attempt). `:stop` adds `status`, `request_id`, and `error`. `:retry` adds `retry`, `max_retries`, and `reason`; its `attempt` is the attempt that failed, and `max_retries` is the effective total for the call, per-call `retry:` included.
3. `error` on `:stop` is `nil` for any HTTP response, and otherwise the `TypeSafe.Error.Timeout` or `TypeSafe.Error.Connection` the call returns. `reason` on `:retry` is the HTTP status, or that same error struct.
4. The events `[:typesafe, :request, :start | :stop | :exception]` are reserved for a later span over the whole call. Nothing emits them today.
5. Transport errors are reported on `:stop` with `error:` set. There is no separate error event.
6. A `:start` is followed by exactly one `:stop`, with two limits. A Finch pool-exhaustion raise (ADR 0006 decision 15) skips Req's step that reports attempts, so `TypeSafe.HTTP` emits the `:stop` for that attempt, with `error: %TypeSafe.Error.Connection{reason: :pool_timeout}`, in the rescue that turns the raise into `{:error, :pool_timeout}`. Any other raise out of the adapter propagates as before and leaves its `:start` without a `:stop`. Every `:stop` `duration` runs from its own attempt's `:start`, so the pool-timeout `:stop` measures the failing attempt, not the whole call. The raise escapes `Req.request/2`, and the rescue holds only the telemetry map built before Req's steps ran, not the request. `TypeSafe.Telemetry` therefore keeps the open attempt's number and start time in a per-call `:counters` ref that the request's private data and the rescue share (PR #21, deviation 1, accepted by the operator).
7. `request_number` comes from `System.unique_integer([:positive, :monotonic])`, taken once per call. It is the same for every attempt and retry of a call and different for every call.
8. The events fire in the process that made the call, on every call, whatever the client's `log_level`. `log_level: :off` does not stop events; it stops the default logger's lines.

### Level model

9. Every event carries the emitting client's resolved `log_level` in its metadata (E1). The level is per client: two clients in one VM keep their own.
10. The default logger is one VM-global handler with the id `"typesafe-default-logger"`. It has no level option of its own. It keeps a line when the line's level ranks at or above the client's level, with the JS ranking `debug < info < warning < error < off` (`logging.ts:34-48`). The SDK emits `:debug` and `:info` lines only, as the JS client does, so `:warning` (the default) and `:error` print nothing, and so does `:off`.
11. `TypeSafe.attach_default_logger/1` takes no keys in this slice; an unknown key returns `{:error, %TypeSafe.Error{}}`, as does a non-keyword list. It returns `:ok` or `{:error, :already_exists}`. `TypeSafe.detach_default_logger/0` returns `:ok` or `{:error, :not_found}`. Both are `:telemetry`'s own results (E2).
12. The application's `Logger` level also has to allow `:info` or `:debug`. The SDK does not change it.

### Detail and redaction

13. URL, headers, and bodies appear in metadata only when the client's `log_level` is `:debug`, and under no key at any other level (E6). At `:debug`, `:start` carries `url`, `headers`, and `body`, and `:stop` carries `body` for a response.
14. `headers` has Req's shape: a map from lowercase name to a list of values. The SDK redacts it before `:telemetry.execute/3`, so no handler sees the value of a credential header, except an allowed scheme word and the last four graphemes of a secret longer than eight (decisions 15 and 16), and the `%Req.Request{}` is never put in metadata. A header outside that list, such as a custom `default_headers` entry, is reported as given.
15. Redaction follows `logging.ts:53-79`, with deviations. `authorization`, `proxy-authorization`, and `x-api-key` are matched case-insensitively and each value is masked. The value is split on its first run of whitespace, and only the first two words count: the first is the candidate scheme, the second is the secret, and a third or later word is ignored (JS `split(/\s+/, 2)`). When the candidate, compared case-insensitively, is `bearer`, `basic`, `token`, `digest` or `negotiate`, it is kept as given, `***` replaces the secret, and the last four graphemes of the secret follow only when it is longer than eight. A value that contains whitespace and has any other first word, including the empty first word of leading whitespace, becomes exactly `***`, with no tail: a tail exposed short secrets such as `"Custom abcd"` (`***abcd`). A value with no whitespace becomes `***` followed by its last four graphemes when it is longer than eight. Tails count grapheme clusters, not code points, so a combining sequence is never cut in the middle (operator decision on finding F2, PR #24). Whitespace is PCRE Unicode `\s` plus U+FEFF on valid UTF-8, and ASCII `\s` on invalid UTF-8, where the Unicode mode would raise, so redaction never raises. This is not exact JS parity: U+0085 and U+180E count as whitespace here and not in JS, so this code masks more than JS does, which is the safe direction. JS treats any first word as a scheme (`logging.ts:64-68`), so `"LETTERSONLYSECRETKEY x"` or a key with a space after a dashed prefix would be logged in part. The allowlist is a deliberate deviation (typesafe-ai/typesafe-sdk-js#18, issue #22). `cookie` and `set-cookie` become `***`. A credential header value that is not a binary becomes `***`. Every value of a multi-value header is masked.
16. The last four graphemes of the API key therefore appear in the `:debug` request line and in `:debug` event metadata, as they do in JS. The raw key appears nowhere.
17. `body` on `:start` is the JSON string the SDK sent, or `nil` for a `GET`. `TypeSafe.Telemetry` converts it from iodata, and the SDK's encoding of request bodies is unchanged (ADR 0003 decision 15). `:debug` therefore prints request bodies, which hold the caller's `state` and question text, and response bodies, unredacted. Only credential headers are masked. The operator's E6 decision supersedes issue #13's "never state or question text" rule, for `:debug` only (https://github.com/vinnie357/typesafe_sdk_ex/issues/13#issuecomment-5919115403).
18. The URL has its `userinfo` removed before it is reported. JS logs the URL as configured.

### Format

19. The default logger writes each line through `Logger.log/2` with the prefix `[typesafe-sdk] ` and the JS text verbatim (E3), where `#N` is the request number, `METHOD` is upper case, and `path` is `/v1/models` or `/v1/systemone`:
    - `#N METHOD path -> url <inspect of %{headers:, body:}>` at `:debug`, before the attempt (`client.ts:368`).
    - `#N METHOD path <- status in Nms`, with ` (request <id>)` when the response has a non-empty request id (JS omits the suffix for an empty one), at `:info` (`client.ts:390`).
    - `#N METHOD path <- body <inspect>` at `:debug` for a 2xx response, or `#N METHOD path <- error body <inspect>` for any other status, after the summary line (`client.ts:344,396`).
    - `#N METHOD path timed out after Nms` at `:info` (`client.ts:436`).
    - `#N METHOD path connection error after Nms <inspect of the error>` at `:info` (`client.ts:439`).
    - `#N METHOD path retrying in Nms (retry n/total) after <reason>` at `:info` (`client.ts:462`). `reason` is the status, or the error's `message`.
20. Debug detail is rendered with `inspect/1` (E3), so it is Elixir syntax and is subject to `inspect`'s default limits.

### Never raise

21. Emission never changes a call's result. The request step that emits `:start`, the retry callback's emission, and the pool-timeout emission each catch anything they raise. They read the telemetry state from the request's private data with a pattern that falls through, so a request built without that state (as `TypeSafe.Retry.decide/2`'s direct tests do) emits nothing.
22. The default handler cannot raise: `log_lines/3` has a catch-all clause that returns no lines, and the handler rescues anything else. `:telemetry` detaches a handler that raises, for the rest of the VM, so a raise in the default logger would silence it for every client. A custom handler that raises is detached the same way, and the call that fired it still returns its normal result.

### Dependency

23. `:telemetry` is a direct dependency, `{:telemetry, "~> 1.0"}`, locked at 1.4.2 as before (ADR 0002).

### Test seams

24. `TypeSafe.Telemetry.log_lines/3` and `redact_headers/1` are pure functions, `@doc false`, that tests call directly. `test/support/telemetry_forwarder.ex` forwards events to a test process, and ADR 0012 decisions 13 to 15 describe it.

## Consequences

### Positive

- An application chooses its own sink: attach the default logger, or handle the events with its own telemetry pipeline.
- The JS log text is reproduced, so a log line can be compared with the JS SDK's.
- The per-client level needs no process and no global setting.

### Negative

- Request numbers are VM-wide. JS numbers per client from `#1` (`client.ts:257,340`), so a log from two clients, or a VM that has made other calls, does not start at `#1`.
- Header names are lowercase, in Req's list-valued shape. JS logs `Record<string, string>` with the casing it sent.
- The `:start` body is the JSON string. JS logs the request object (`client.ts:368-371`).
- There is no `logger:` option (ADR 0001): the sink is `:telemetry` and `Logger`.
- There are no abort lines (`client.ts:432,466`): the SDK has no `AbortSignal` (ADR 0001).
- Debug detail is rendered with `inspect/1`, not JS's console formatting.
- A `:start` whose adapter raised something other than a pool timeout has no `:stop`.
- An invalid `TYPESAFE_LOG_LEVEL` still falls back to `:warning` silently (ADR 0004 decision 11, E7). JS throws `Invalid log level ... from TYPESAFE_LOG_LEVEL` (`logging.ts:13-18`). A typo in the variable therefore turns logging off without a message.
- The URL loses its `userinfo` (decision 18), which JS does not do.
- A credential header value that contains whitespace and whose first word is not an allowed scheme is masked as exactly `***`, where JS would keep that word (decision 15). A value with no whitespace still ends in its last four graphemes when it is longer than eight.
- Only whitespace splits a credential header value: PCRE Unicode `\s` plus U+FEFF on valid UTF-8, and ASCII `\s` otherwise. Any other code point does not split, so a value separated only by such a code point is treated as having no whitespace and keeps a tail of at most four graphemes: `"Custom\u200Babcd"` (an Elixir escape for a zero-width space) becomes `"***abcd"` (observed). Examples observed to behave this way are U+200B (zero-width space), U+200C, U+200D, U+2060, the bidi controls U+200E and U+202E, and the filler U+3164 (PR #24 re-attestation, finding N1; issue #22). U+0085 and U+180E are whitespace here and not in JS.
- `:debug` prints bodies that can hold user data (decision 17).

## Alternatives considered

- **A `logger:` option like JS.** Rejected by operator decision (E1, E2): the events are the interface, and a second sink option would duplicate it.
- **A handler-level knob on the default logger.** Rejected (E1): the level lives on the client, so two clients in one VM can differ.
- **Emit events only at or above the client's level.** Rejected: a handler of the application's own would then depend on a setting meant for the logger.
- **`Logger` calls inside the SDK.** Rejected: the application could not route or drop them, and the level would be global.
- **A process for request numbers.** Rejected: `System.unique_integer/1` needs none.
- **Metadata carrying the `%Req.Request{}`.** Rejected: it holds the `authorization` header.

## References

- JS: `logging.ts:5-79`, `client.ts:257,276,340-399,431-466` at the commit in ADR 0001.
- Issue #13, operator decisions E1 to E7 (2026-09-30): https://github.com/vinnie357/typesafe_sdk_ex/issues/13
- Issue #13, operator decisions from the ADR audit (E6 supersedes the text rule for `:debug`; `async: false` ratified): https://github.com/vinnie357/typesafe_sdk_ex/issues/13#issuecomment-5919115403
- PR #21: https://github.com/vinnie357/typesafe_sdk_ex/pull/21#issuecomment-5917353310
- Issue #22: https://github.com/vinnie357/typesafe_sdk_ex/issues/22#issuecomment-5918195463 and https://github.com/vinnie357/typesafe_sdk_ex/issues/22#issuecomment-5918325256
- PR #24: https://github.com/vinnie357/typesafe_sdk_ex/pull/24#issuecomment-5918617573, https://github.com/vinnie357/typesafe_sdk_ex/pull/24#issuecomment-5918792932, https://github.com/vinnie357/typesafe_sdk_ex/pull/24#issuecomment-5918926569
- `test/typesafe/telemetry_test.exs`, `test/typesafe/default_logger_test.exs`, `test/support/telemetry_forwarder.ex`.
- `telemetry@1.4.2`: handler detach on a raising handler, observed in the test `"a crashing handler never makes a call raise, and telemetry detaches it"`.
