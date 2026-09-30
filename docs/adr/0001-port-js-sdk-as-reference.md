# ADR 0001: Port the JS SDK v0.6.0 as the behavioral reference

**Status:** Accepted
**Date:** 2026-09-17; upstream re-verified 2026-09-29

## Context

TypeSafe publishes three sources of truth for its client: the JS SDK, the Python SDK, and the pages at `docs.typesafe.ai`. They disagree in places (see the table below). A port needs one tiebreak, so each later decision can cite one authority and record only its deviations.

On 2026-09-29 the JS repository was identical to the pinned commit: the GitHub compare `66880cc...HEAD` reported "identical, ahead_by 0", and `main` was v0.6.0. No retry, timeout, Retry-After, error, or logging behavior had drifted.

## Decision

1. The behavioral reference is `typesafe-ai/typesafe-sdk-js` at commit `66880ccded6cb642dc1809620c2b108c33730214`, version 0.6.0 (`src/version.ts:2`).
2. Where `docs.typesafe.ai` and the JS source disagree, the port follows the JS source.
3. Where the JS and Python SDKs disagree, the port follows JS.
4. The port records each deliberate deviation from JS in exactly one ADR. The index below names the owner.
5. The port does not implement the JS features in the "Not ported" table.
6. A new deviation needs its own ADR or an amendment to the owning ADR, in the same PR as the code.

### Docs versus JS: rulings

| Question | Docs / Python | JS | Ruling and owner |
|---|---|---|---|
| Is `instructions` required? | `api.md` marks it required on all three question types (`api.md:L79,L120,L158`) | Optional or `null` (`types.ts:24,43,55`; default `null` at `questions.ts:23`) | Follow JS. The SDK does not validate it. ADR 0011 |
| Is `state: null` valid? | `api.md` types `state` as `string \| object \| array`, required (`api.md:L23`) | `EntryType` includes `null` (`types.ts:11,162`) | Follow JS. ADR 0011 |
| What types do descriptions take? | The pre-split spec recorded `api.md` typing noul `true`/`false` as strings and choice criteria as `string \| null`. On 2026-09-29 `api.md` types them as string, object, or array (`api.md:L87,L124,L162`; `primitives/choice.md:L314`). | String, object, array, or `null` (`types.ts:11,17-31`) | Follow JS. The docs now agree. ADR 0011 |
| Are level and option counts bounded? | Score takes up to 10 levels (`primitives/score.md:L564`); choice takes up to 255 options (`primitives/choice.md:L355`) | Checks only `>= 2` for score (`questions.ts:82`) | Follow JS. The server's 422 enforces the upper bounds. ADR 0011 |
| Which error statuses exist? | `api.md` lists 401, 422, 429, 529 (`api.md:L329-L334`) | Maps 400, 403, and 404 as well; the live test expects `400 Unknown model: no-such-model` (`test/integration/api.integration.ts:116-127`) | Follow JS. ADR 0006 |
| Is `GET /v1/models` documented? | In `models.md`, not in `api.md` | `src/resources/models.ts` | Ported. ADR 0003 |
| What type are `legend` values? | `api.md`: `map<string, string>` (`api.md:L291`); Python allows `str \| dict \| list` (`sdk/python/api/types/responses.md:L1184`) | The original descriptions (`types.ts:98-100`) | Follow JS. Responses are unvalidated. ADR 0003 |
| Does the SDK read `retry-after-ms`? | `models.md` says SDKs honor `retry-after` (`models.md:L19`) | Reads `retry-after-ms` first (`retry.ts:38-40`) | Follow JS. ADR 0009 |
| Is there a total retry budget? | Python `RetryPolicy.timeout` is 30 s total (`sdk/python/api/retries.md:L428-L430`) | None (`types.ts:200`) | Follow JS. ADR 0010 |
| Are there retry `exceptions` and `predicate`? | Python has both (`sdk/python/api/retries.md:L364,L376`) | Rejected at type level (`test/types.test-d.ts:132-133`) | Follow JS: not ported. ADR 0007 |
| Are responses validated? | Python raises `TypeSafeAPIResponseValidationError` (`sdk/python/api/exceptions.md`) | Returns unvalidated JSON, except the `/v1/models` shape | Follow JS. ADR 0003 |
| What is the log level spelling? | Python uses `warning` | `warn` (`logging.ts:5-7`) | The env variable accepts both. ADR 0004 |
| What is the call shape? | Python: `system_one(state, questions, *, model, retry, timeout, extra_headers, extra_body)` | One request object with spread extras | Follow JS: `system_one(client, %{state:, questions:} = request, opts)`. ADR 0003, ADR 0011 |

### Deviation index

| Deviation from JS | Owner |
|---|---|
| Constructor and validation failures return `{:error, _}` instead of throwing | ADR 0003 |
| `system_one/3` requires an atom-keyed request with `:state`; JS drops `state: undefined` | ADR 0011 |
| An explicit blank `api_key` is an error per the operator ruling, and the code falls back to the env key (open, issue #10); JS sends `Bearer ` | ADR 0004 |
| An unrecognized `TYPESAFE_LOG_LEVEL` falls back to `:warning`; JS throws | ADR 0004 |
| The `log_level` option takes atoms only; JS takes the strings | ADR 0004 |
| `User-Agent`, `X-TypeSafe-SDK`, and `X-TypeSafe-Runtime` carry Elixir values | ADR 0005 |
| `req_options` cannot override SDK-owned settings; the header surface is a one-value map | ADR 0005 |
| Raw-body error messages use the original body text; the `Timeout` struct is separate from `Connection` | ADR 0006 |
| Millisecond retry fields are integers | ADR 0007 |
| `api_timeout_error` defaults to `false` | ADR 0008 |
| Retry-After grammar is strict, blank is `nil`, the first header value wins, results are integers | ADR 0009 |
| A Retry-After HTTP date ignores its timezone token and reads as UTC | ADR 0009 |
| `timeout` is a positive integer with an upper bound and bounds each socket read, not connecting | ADR 0010 |
| Builders raise `FunctionClauseError` instead of throwing `TypeSafeError` | ADR 0011 |

### Not ported

| JS feature | Replacement |
|---|---|
| `APIPromise` lazy thenable, `.map`, `.asResponse` (`api-promise.ts:7-78`) | Calls are synchronous. `with_response: true` returns the data, the `%Req.Response{}`, and the request id (ADR 0003). Callers who need async use `Task`. |
| `AbortSignal` and `APIUserAbortError` (`client.ts:413-417,450-469`, `types.ts:199`, `errors.ts:118`) | None. The BEAM has no signal primitive; callers cancel by killing the calling process or `Task`. |
| Browser guard and `dangerouslyAllowBrowser` (`client.ts:60-65,268`) | None. The BEAM never runs in a browser page. |
| Runtime detection (`runtime.ts:21-31`) | A fixed Elixir/OTP string in `X-TypeSafe-Runtime` (ADR 0005). |
| Custom `fetch` and the global-fetch receiver fix (`client.ts:54-68,281-282`) | `req_options` (ADR 0005). |
| `bufferResponse` stalled-body abort (`client.ts:180-201`, `release-regressions.test.ts:85-146`) | Req and Finch read the full body; `receive_timeout` bounds each read (ADR 0010). |
| `__proto__` question preservation (`release-regressions.test.ts:72-83`) | None. Elixir maps have no object-prototype hazard. |
| Policy mutation isolation (`reliability.test.ts:201-247`) | None. Elixir data is immutable. |
| ESM, CJS, and JSR packaging, tsdown, dist tests | A Hex package. |
| Type-level tests (`test/types.test-d.ts`) | None. The SDK infers no answer types (ADR 0003). |
| `ENV` constant as a runtime value | Documented in `TypeSafe.new/1`; no public function. |
| Logging, the `logger` option, and credential redaction (`src/logging.ts`) | Not built. `log_level` is accepted and has no effect (ADR 0004). The design notes are in the [last full spec](https://github.com/vinnie357/typesafe_sdk_ex/blob/e83f7a28c126f6f9ead2fb14bf8edcd3a9efd4c4/docs/spec.md) (section 7), which no ADR endorses. |

## Consequences

### Positive

- Each behavior question has one authority, and the JS tests double as a source of expected values. The test files cite JS test lines in comments.
- A reader can list every place the port differs from JS from the deviation index.

### Negative

- The docs-versus-JS rulings rest on reading the JS source. The live API's answer to an omitted `instructions`, a `null` state, or an eleven-level score is unverified, because no live-API tests exist. The server may reject inputs the SDK sends.
- JS parity inherits JS gaps. The port does not add response validation, upper bounds on levels, or an idempotency key.
- The port trails the JS SDK. A new upstream release needs a fresh comparison and, where behavior changed, an amended ADR.

## Alternatives considered

- **Follow the docs where they disagree with JS.** Rejected. The docs contradict each other (`api.md` versus `primitives/choice.md` on description types), and the JS test suite pins the observed behavior.
- **Follow the Python SDK.** Rejected. The Python SDK adds a 30 s total retry budget and response validation. The Elixir call shape follows the JS request object, which matches the JS tests the port reuses.
- **Port JS logging, `AbortSignal`, and `bufferResponse` too.** Rejected for now: the BEAM lacks an equivalent for the first two, and Req/Finch cover the third at a different granularity.

## References

- JS SDK: https://github.com/typesafe-ai/typesafe-sdk-js/tree/66880ccded6cb642dc1809620c2b108c33730214 (file:line cites above are relative to that commit)
- Docs pages (fetched 2026-09-17 and 2026-09-29): https://docs.typesafe.ai/api.md, https://docs.typesafe.ai/models.md, https://docs.typesafe.ai/primitives/choice.md, https://docs.typesafe.ai/primitives/score.md, https://docs.typesafe.ai/sdk/python/api/retries.md, https://docs.typesafe.ai/sdk/python/api/exceptions.md
- PR review that records the spec as design rationale worth keeping (D6): https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5722393470
