# TypeSafe SDK — Elixir port spec (P1)

Source: `typesafe-ai/typesafe-sdk-js` @ `66880ccded6cb642dc1809620c2b108c33730214`, version `0.6.0` (`src/version.ts:2`).
Citation forms:
- `path:line` is a line in that JS repo.
- `<page>.md:Lnn` is a raw Markdown doc page fetched 2026-09-17 from `https://docs.typesafe.ai/<page>.md`, for example `api.md:L64` → https://docs.typesafe.ai/api.md.
- `req@0.7.4 <file>:line` is the Req version locked in the scaffold (`/Users/vinnie/github/typesafe_sdk_ex/mix.lock`, read-only).
- `verified:` marks a behavior observed by running `scratchpad/verify/adapter_check.exs` and `scratchpad/verify/logcheck/test/log_test.exs`. Both ran against the scaffold's compiled `_build/dev/lib` (Req 0.7.4) on Elixir 1.19.5 / OTP 28.4.2, which `mise.toml` pins, and both exited 0.

**Dependency constraint (operator directive):** the runtime dependency is `req` only, which brings `jason` in transitively; `credo` is CI-only. There is no `plug`, `ex_doc`, Mox, NimbleOptions, or direct Jason call.

---

## 1. Summary

1. Client for one inference endpoint, `POST /v1/systemone`, which answers named typed questions about a `state` (`src/client.ts:311-325`, `api.md:L11-L17`). It also covers `GET /v1/models` (`src/resources/models.ts:15-17`, `models.md:L38-L40`).
2. Three question builders, `noul` / `choice` / `score`, emit plain wire objects (`src/questions.ts:22-63`). The client validates questions before it sends anything (`src/questions.ts:70-89`).
3. Configuration resolves in this order: explicit option, then env var, then default (`src/client.ts:267-289`, `src/env.ts:1-23`).
4. Reliability layer: a per-attempt timeout, and retries with capped exponential backoff plus jitter that honor `Retry-After`/`retry-after-ms` (`src/retry.ts`, `src/client.ts:350-470`).
5. Non-2xx responses become a status-mapped error hierarchy (`src/errors.ts:69-78`). Logging is level-filtered and redacts credential headers (`src/logging.ts`).

## 2. Public API inventory → Elixir mapping

Every export of `src/index.ts:1-22`:

| JS export (cite) | Elixir mapping |
|---|---|
| `TypeSafeClient` class (`index.ts:2`, `client.ts:234`) | `%TypeSafe.Client{}` struct built by `TypeSafe.new(opts) :: {:ok, Client.t()} \| {:error, %TypeSafe.Error{}}`. JS throws at construction (`client.ts:265`); Elixir returns `{:error, _}` because of the no-bang convention. |
| `client.systemOne(request, options)` (`client.ts:311`) | `TypeSafe.system_one(client, request :: map, opts \\ []) :: {:ok, map} \| {:error, Exception.t()}` |
| `client.models.list(options)` (`models.ts:15`) | `TypeSafe.list_models(client, opts \\ []) :: {:ok, [map]} \| {:error, Exception.t()}`. The JS `Models` class is a namespace only (`models.ts:7-18`), so no separate module. |
| `APIPromise`, `WithResponse` (`index.ts:1`, `api-promise.ts:7-78`) | Not ported (§9). Replaced by the `with_response: true` option, which returns `{:ok, %{data: _, response: %Req.Response{}, request_id: _}}` and mirrors `WithResponse` (`api-promise.ts:7-14`). |
| `ENV`, `EnvVar` (`index.ts:3`, `env.ts:2-13`) | Documented in `@moduledoc`, with no public function (restraint rung 1). |
| `TypeSafeError` (`errors.ts:5`) | `TypeSafe.Error` exception with field `message`, used for config and validation failures. |
| `APIError` + 7 subclasses (`errors.ts:42-97`) | One exception struct per status class under `TypeSafe.Error.*` (§6). |
| `APIConnectionError`, `APITimeoutError` (`errors.ts:100-115`) | `TypeSafe.Error.Connection`, `TypeSafe.Error.Timeout` |
| `APIUserAbortError` (`errors.ts:118`) | Not ported (§9) |
| `LOG_LEVELS` (`index.ts:18`, `logging.ts:5`) | `@type log_level :: :debug \| :info \| :warning \| :error \| :off` |
| `choice`, `noul`, `score` (`index.ts:19`) | `TypeSafe.choice/2`, `TypeSafe.noul/0,1,2`, `TypeSafe.score/2` (§8) |
| `Models` type (`index.ts:20`) | none |
| `export type * from "./types"` (`index.ts:21`, `types.ts`) | `@type`s only: `request`, `question`, `system_one_result`, `model_card`. No structs for responses (§8). |
| `VERSION` (`index.ts:22`) | `TypeSafe.version/0` → `Application.spec(:typesafe_sdk_ex, :vsn)` |
| `RetryPolicy` type (`types.ts:175-194`) | `%TypeSafe.RetryPolicy{}` struct with the §5 defaults. Overrides are keyword lists: `retry: [max_retries: 0]`. |

Client struct fields map to the readonly JS properties (`client.ts:236-255`): `base_url`, `default_model`, `log_level`, `retry`, `timeout`, `default_headers`, `req` (the configured `Req.Request`). The API key lives only inside `req`, as the bearer auth header. Req's `Inspect` for `Req.Request` redacts the `authorization` value (`req@0.7.4 lib/req/request.ex:1157-1165`), which covers `client.test.ts:82-87`.

## 3. HTTP contract

**Base URL.** Default `https://api.typesafe.ai` (`client.ts:41`, `api.md:L14`). Trailing slashes are stripped (`client.ts:164,271-273`). The final URL is `base_url <> path` (`client.ts:351`).

**Endpoints**

| Method / path | Request body | Success body | Cite |
|---|---|---|---|
| `POST /v1/systemone` | `{state, questions, model, ...extra}`. The caller's request map is spread and `model` is filled from `default_model` when absent. Extra top-level keys, including `null`s, are forwarded. | `{model: string, answers: {id => answer}, usage: {input_tokens, output_tokens}}`, returned unvalidated | `client.ts:315-324`, `types.ts:155-172`, `client.test.ts:212-221,413-426`; `api.md:L19-L39,L165-L204` |
| `GET /v1/models` | none | `{models: [{name, description, release_date}]}`. The SDK unwraps it to the list, and any shape other than a list under `models` is an error. | `models.ts:15-27`, `client.test.ts:164-185`; `models.md:L67-L83` |

**Answer shapes** (`types.ts:73-115`; `api.md:L206-L308`):
- noul: `{type:"noul", noul: 0..1}`
- choice: `{type:"choice", choice: label, confidence, probabilities: {label => p}}`
- score: `{type:"score", score: float, confidence, legend: {"0" => desc, ...}, probabilities: {"0" => p, ...}}`. Score keys are strings on the wire (`api.md:L280-L286`).

**Headers sent on every attempt** (`client.ts:352-367`). Caller headers are merged first and SDK headers win. Matching is case-insensitive, last value wins, and `undefined` deletes (`client.ts:166-178`).

| Header | Value | Notes |
|---|---|---|
| `Authorization` | `Bearer <api_key>` | Callers cannot override it (`client.test.ts:149-162`). |
| `Accept` | `application/json` | protected |
| `User-Agent` | `typesafe-sdk/<VERSION>` | protected. Elixir value is an open question (§12). |
| `X-TypeSafe-SDK` | `typesafe-sdk/<VERSION>` | protected |
| `X-TypeSafe-Runtime` | e.g. `node/22.1.0 (darwin; arm64)` (`runtime.ts:21-31`) | protected. Elixir value is an open question (§12). |
| `Content-Type` | `application/json`, only when a body is present | A caller's content-type is removed on GET (`release-regressions.test.ts:60-70`). |
| `X-TypeSafe-Retry-Count` | absent on attempt 0; `"1"`, `"2"`, … on retries | A caller's value is always removed (`client.ts:360,366-367`, `reliability.test.ts:153-166`, `release-regressions.test.ts:15-58`). |

There is no idempotency or `x-should-retry` header anywhere in src, test, or docs (grep found no match).

Header precedence: `default_headers` < per-call `headers` < protected SDK headers (`client.ts:333,353`).

**Response headers read.** `x-typesafe-request-id` (`api-promise.ts:1-4`), plus `retry-after-ms` and `retry-after` (`retry.ts:38-49`).

**Body parsing** (`client.ts:472-489`). An empty body parses to `nil`. Otherwise the client tries JSON whatever the content-type, and falls back to raw text on a parse failure (`errors.test.ts:104-133`).

Req's default decoder picks a format by content-type (`req@0.7.4 lib/req/steps.ex:1160-1175`), so it cannot parse JSON sent without one. The port therefore sets `decode_body: false` and calls Elixir's built-in `JSON.decode/1`. verified: it returns `{:ok, %{"a" => 1}}` for JSON and `{:error, {:invalid_byte, 0, 60}}` for HTML. Request bodies are encoded with Req's `:json` option, which also sets `content-type` and `accept` (`steps.ex:489-492`).

**`decode_body` is SDK-owned (Gate 4 review N12).** `req_options` (§4) is a caller-supplied keyword list merged into `Req.new/1`, but `decode_body: false` above is a hard SDK requirement, not a mere default: the port's own JSON decoding depends on it. A caller-supplied `req_options: [decode_body: ...]` is therefore **overridden**, not rejected — `new/1` still returns `{:ok, client}`, and the client's `decode_body` stays `false` regardless of what `req_options` requested.

**Env vars** (`env.ts:2-11`):

| Var | Option | Default |
|---|---|---|
| `TYPESAFE_API_KEY` | `api_key` | required |
| `TYPESAFE_BASE_URL` | `base_url` | `https://api.typesafe.ai` |
| `TYPESAFE_DEFAULT_MODEL` | `default_model` | `jev-latest` (`client.ts:42`) |
| `TYPESAFE_LOG_LEVEL` | `log_level` | `warn` (`logging.ts:7`) |

Precedence is explicit option, then env, then default. JS treats only `undefined` as "not given" (`env.ts:22-23`, `??`). Env values are trimmed, and blank means unset (`env.ts:16-19`, `client.test.ts:89-98`). Elixir: `new/1` reads env through a `:get_env` option, a `(String.t() -> String.t() | nil)` function that defaults to `&System.get_env/1`. Tests pass `get_env: fn name -> Map.get(env, name) end`, so process env is never mutated.

## 4. Client options and defaults

| Option (JS → Elixir) | Default | Scope | Validation (cite) |
|---|---|---|---|
| `apiKey` → `api_key` | env | client | missing → `TypeSafe.Error`, and the message names `TYPESAFE_API_KEY` (`client.ts:48-52`, `client.test.ts:100-103`) |
| `baseURL` → `base_url` | env, then default | client | strip trailing `/` |
| `defaultModel` → `default_model` | env, then `jev-latest` | client. Per call through `request.model` (`client.ts:318`). | — |
| `logLevel` → `log_level` | env, then `warn` | client | must be one of the levels, and the error names its source: `"loud" from TYPESAFE_LOG_LEVEL` or ``the `logLevel` option`` (`logging.ts:13-18`, `client.ts:157-162`, `client.test.ts:119-128`) |
| `logger` → `logger` (§7) | Logger | client | — |
| `retry` → `retry` (keyword) | §5 | client **and** per call. Merged field by field with the client policy (`client.ts:337`, `reliability.test.ts:383-400`). | §5 |
| `timeout` → `timeout` (ms) | `10_000` (`retry.ts:5`) | client **and** per call (`client.ts:335-336`) | positive (`client.ts:77-84`, `reliability.test.ts:524-534`) |
| `defaultHeaders` → `default_headers` | `%{}` | client. Per call: `headers` (`types.ts:205`). | — |
| `fetch` → `req_options` (keyword merged into `Req.new/1`; tests pass `adapter: TypeSafe.StubAdapter`, see §11) | `[]` | client | — |
| — → `get_env` | `&System.get_env/1` | client | test seam for env (§3) |
| `dangerouslyAllowBrowser` | — | not ported (§9) | — |
| `signal` (per call, `types.ts:199`) | — | not ported (§9) | — |
| — → `with_response` (per call) | `false` | call | Elixir replacement for `.withResponse()` |

Option **keys** are checked with `Keyword.validate/2`. verified: it returns `{:ok, merged_with_defaults}`, or `{:error, [:bogus]}` for an unknown key. Option **values** are checked with guard clauses written for the purpose.

Per-call validation errors (bad `timeout` or `retry`) come back before any request is sent (`reliability.test.ts:168-180,402-421`). Elixir returns `{:error, %TypeSafe.Error{}}` in that case.

**`req_options` cannot override SDK-owned request settings (Gate 4 review round 2, R2, operator decision).** `req_options` is the caller's escape hatch into `Req.new/1` — the Elixir analogue of JS's `fetch` option — not a route around the client's own guarantees. `base_url` and `auth` are forced the same way `decode_body` and `retry` already are (§3): a `req_options: [base_url: ...]` or `req_options: [auth: ...]` value is silently overridden, so the client's configured `base_url` and `authorization` header are what the request actually uses, regardless of what `req_options` requests. `receive_timeout` is handled differently: it is **rejected** at `new/1` with `{:error, %TypeSafe.Error{}}` naming the option, not silently overridden — `receive_timeout` has its own future `:timeout` option (§5, S3), so accepting it via `req_options` and then ignoring it would be a silent no-op that misleads a caller into believing their timeout took effect. **Scope of this protection (Gate 4 follow-up on 6701bd5):** only `base_url`, `auth`, `decode_body`, `retry`, and `receive_timeout` are handled specially. Every other `Req.new/1` option — `pool_timeout`, `connect_options`, and the rest — passes through `req_options` unvalidated today; S3 (retry/timeout semantics) is expected to revisit the remaining timeout-related keys (e.g. `pool_timeout`) as part of its own scope, not this one.

**Header values are a simple map, not Req's native multi-value list form (Gate 4 review round 2, R3, operator decision).** A header value must be a binary, an atom, or a number (atoms and numbers are coerced to strings, matching `to_string/1`); `nil` deletes the header instead of sending it empty or as the literal string `"nil"` (§3 L62 already establishes the delete-on-nil rule for the existing per-call/default-headers path). A list value — Req's own multi-value header representation — is **rejected**, not coerced and not accepted: the SDK's header surface (`default_headers`, per-call `headers`) is deliberately a simple one-value-per-name map, unlike Req's `Req.Request.t()` headers, which are `%{String.t() => [String.t()]}`. A caller needing repeated header names is expected to use `req_options` directly (subject to the protections above) rather than the SDK's own `headers`/`default_headers` options. The `headers` container itself must be a map — `nil` or a binary for the whole option is rejected, not treated as "no headers."

**`inspect(%TypeSafe.RetryPolicy{})` renders `http_statuses` compactly, all fields kept visible (operator decision, new).** The default derived `Inspect` enumerates the ~100 individual members of the `http_statuses` `MapSet` in hash order, which is unreadable and useless for confirming the default policy. The intended rendering keeps every one of the struct's nine fields visible — nothing is hidden to make the output shorter — and renders `http_statuses` as a compact summary reading (in this shape) `408, 429, 500..599` — read as "exactly {408, 429} ∪ 500..599, and nothing else" — via a custom `Inspect` implementation. This affects `inspect/1` on a bare `%TypeSafe.RetryPolicy{}` and, because it is a nested field, on any `%TypeSafe.Client{}` value too.

## 5. Retry and timeout semantics

**Default policy** (`retry.ts:11-23`; confirmed by `sdk/javascript/api/interfaces/RetryPolicy.md`):

| Field (Elixir) | Default | Validation (`client.ts:111-147`) |
|---|---|---|
| `max_retries` | 2 | non-negative integer (`client.ts:70-75`) |
| `backoff_initial_ms` | 500 | non-negative number |
| `backoff_max_ms` | 5000 | non-negative |
| `backoff_jitter` | 0.25 | between 0 and 1 inclusive |
| `http_statuses` | `MapSet` of 408, 429, 500..599 | integers from 100 to 999 (`client.ts:102-109`) |
| `respect_retry_after` | true | boolean |
| `max_retry_after_ms` | 60_000 | non-negative, finite |
| `api_connection_error` | true | boolean |
| `api_timeout_error` | true | boolean |

**Retry decision** (`client.ts:364-400`), where attempt `n` counts from 0 and `retries_left = max_retries - n`:
- Transport error: retry when `retries_left > 0` and the error is a `Timeout` with `api_timeout_error` set, or a `Connection` with `api_connection_error` set (`client.ts:150-154,383-384`). A timeout is checked before a connection error.
- HTTP response: 2xx returns. Otherwise build the mapped error, and retry only when `retries_left > 0` and the status is in `http_statuses` (`client.ts:393-399`). 400, 401, 403, 404, 409, 422, and 600 do not retry by default (`retry.test.ts:42-44`).
- After retries run out, the **last** error is returned (`reliability.test.ts:94-99`).

**Delay** (`retry.ts:56-68`):
1. When `respect_retry_after` is set and the response has headers, parse the Retry-After delay. If it is not nil and `<= max_retry_after_ms`, use it exactly, with no jitter (`retry.test.ts:95-105`).
2. Otherwise the delay is `round(min(backoff_initial_ms * 2^attempt, backoff_max_ms) * (1 - random() * backoff_jitter))` with `random ∈ [0,1)`. Defaults with no jitter give 500, 1000, 2000, 4000, 5000, 5000 (`retry.test.ts:84-88`). Maximum jitter gives 375 at attempt 0 (`retry.test.ts:90-93`).
3. Transport errors have no headers, so they always use backoff (`client.ts:385`).

**Retry-After parsing** (`retry.ts:38-49`):
- `retry-after-ms` wins when present and it is a finite number `>= 0`.
- Otherwise `retry-after`: a number `>= 0` means seconds × 1000 (`"1.5"` → 1500). A negative number → nil. An HTTP date → `max(0, date - now)`. Garbage → nil (`retry.test.ts:54-77`).
- Take `now` as a parameter so tests stay pure.
- Req's HTTP-date parser lives in `Req.Utils`, which is `@moduledoc false` (`req@0.7.4 lib/req/utils.ex:2`), so do not depend on it. Use OTP's `:httpd_util.convert_request_date/1`. verified: it returns `{{2026,10,21},{7,28,5}}` without starting `:inets`. Convert with `NaiveDateTime`/`DateTime` from stdlib. Add `:inets` to `extra_applications` so releases include the module (requires verification in a release build).

**Timeout** (`client.ts:403-447`). The timeout applies per attempt and there is no total budget (`types.ts:200`). A timeout produces `Timeout{timeout_ms}` with message `"Request timed out after 1000ms."` (`reliability.test.ts:445-458`). Each retry gets a fresh timeout (`reliability.test.ts:476-491`).

The Elixir mapping is Req `receive_timeout: timeout` (`req@0.7.4 lib/req.ex:445`), and a `Req.TransportError{reason: :timeout}` maps to `Timeout`. The semantics differ; see §12. Do not set a top-level `:pool_timeout`: in 0.7.4 it emits a deprecation warning pointing at `finch: [pool_timeout: ...]` (`req.ex:550-552`). The JS SDK has no pool concept, so Req's default is kept.

**Can Req's built-in `:retry` express this? Yes, with a 2-arity fun.** Verified in the Req 0.7.4 source:
- The default `:safe_transient` retries only GET/HEAD on 408/429/500/502/503/504 (`steps.ex:1670-1680,1720-1722,1775`), so a POST is never retried and 5xx coverage is incomplete. Use `retry: &TypeSafe.Retry.decide/2`. It returns `{:delay, ms}` or `false` (`steps.ex:1682-1690`).
- Req's own Retry-After handling covers only 429/503, reads `retry-after` only, and has no ceiling (`steps.ex:1824-1840`, `response.ex` `get_retry_after/1`). Returning `{:delay, ms}` bypasses it.
- **Why `:retry_delay` is not used.** A `:retry_delay` function receives only the retry count (`steps.ex:1693-1700`), so it cannot see `retry-after-ms` or apply the ceiling. Worse, once `:retry_delay` is set, Req skips Retry-After entirely even on 429/503 (`steps.ex:1826-1828`). Setting `:retry_delay` together with `{:delay, _}` also raises (`steps.ex:1753`).
- **Hand-rolled on top of Req, with reasons:** (1) the delay formula with jitter and the cap, because `:retry_delay` cannot express the Retry-After branch; (2) the Retry-After parser, because Req reads neither `retry-after-ms`, decimals, nor a ceiling; (3) the status set and the per-error flags inside `decide/2`, because `:safe_transient`/`:transient` use a fixed list. Jitter uses `:rand.uniform/0`, whose range is 0.0 ≤ x < 1.0, matching JS `Math.random`.
- Also set `max_retries: policy.max_retries` (`steps.ex:1704,1810-1813`) and `retry_log_level: false`.
- The attempt number is `Req.Request.get_private(request, :req_retry_count, 0)` (`steps.ex:1808`). `run_request/1` re-runs every request step on each retry (`request.ex:1032-1050`). A custom request step can therefore set `x-typesafe-retry-count` from that private counter.
- **Sleep cannot be injected.** Req calls `Process.sleep(delay)` directly (`steps.ex:1815`).
- **The adapter runs inside Req's retry loop, so stubbed tests exercise real Req retries.**
  - The adapter runs at the end of `run_request` (`request.ex:1052-1063`).
  - A response flows into the response steps, where `retry` comes first (`steps.ex:87`). An exception flows into the error steps (`request.ex:1090-1105`), which also start with `retry` (`steps.ex:95`).
  - `do_retry` calls `run_request/1` again (`steps.ex:1817`), and that re-runs the request steps and the adapter (`request.ex:1032-1050`).
  - verified with a module adapter: a POST answered 503, 503, then 200 returned 200 after 3 adapter calls, with `x-typesafe-retry-count` sent as absent, `["1"]`, `["2"]` by an appended request step.
  - verified: an adapter returning `%Req.TransportError{reason: :timeout}` makes `Req.request/2` return `{:error, %Req.TransportError{reason: :timeout}}`.

**Test seam, with no real sleeping:**
- (a) `TypeSafe.Retry.delay_ms(attempt, headers, policy, random_fun)`, `TypeSafe.Retry.parse_retry_after(headers, now_ms)`, and `TypeSafe.Retry.decide/2` are pure. Tests check exact delays through them, with no HTTP.
- (b) Every end-to-end retry test sets `retry: [backoff_initial_ms: 0, backoff_max_ms: 0]`, sends `retry-after-ms: 0`, or sets `respect_retry_after: false` with zero backoff. The computed delay is then 0 and `Process.sleep(0)` returns immediately.
- No `:sleep` option is added (restraint).

## 6. Error taxonomy

`fromResponse` mapping (`errors.ts:69-78`, `errors.test.ts:20-40`):

| Status | JS class | Elixir struct |
|---|---|---|
| 400 | `BadRequestError` | `TypeSafe.Error.BadRequest` |
| 401 | `AuthenticationError` | `TypeSafe.Error.Authentication` |
| 403 | `PermissionDeniedError` | `TypeSafe.Error.PermissionDenied` |
| 404 | `NotFoundError` | `TypeSafe.Error.NotFound` |
| 422 | `UnprocessableEntityError` | `TypeSafe.Error.UnprocessableEntity` |
| 429 | `RateLimitError` (+`retryAfterMs`) | `TypeSafe.Error.RateLimit` (+`retry_after_ms`) |
| ≥500 (incl. 529 Overloaded, `api.md:L319`) | `InternalServerError` | `TypeSafe.Error.InternalServer` |
| any other non-2xx (e.g. 409, 418) | `APIError` | `TypeSafe.Error.API` |
| transport failure | `APIConnectionError`, message `"Connection error: <cause>"` (`client.ts:440-443`) | `TypeSafe.Error.Connection{message, reason}` |
| timeout | `APITimeoutError` (a subclass of Connection) | `TypeSafe.Error.Timeout{message, timeout_ms}`. This is a separate struct because Elixir has no inheritance. |
| config, validation, or bad `/v1/models` shape | `TypeSafeError` | `TypeSafe.Error{message}` |

Every HTTP error struct carries `status`, `body` (decoded JSON, text, or nil), `headers` (a Req header map), `request_id` (`x-typesafe-request-id` or nil), and `message` (`errors.ts:42-58`).

**Message** (`errors.ts:16-37,60-66`). The format is `"<status> <detail>"`. Detail extraction, in order:
1. body is a string → the string
2. `error` is a string
3. `error.message`
4. `message`
5. `detail` is a string
6. `detail.message`
7. `detail` is a list → the `loc` joined with `.` minus `"body"`, then `: msg`, entries joined with `"; "`

With no detail and a nil body the message is `"<status> status code (no body)"`. Otherwise it is the raw body JSON-encoded, truncated to 200 chars plus `…` (`errors.test.ts:42-133`). Elixir uses the **original response body text** instead of re-encoding the decoded term. Stdlib `JSON` offers only bang encoders (`JSON.encode!/1`, `JSON.encode_to_iodata!/1`), and re-encoding is unnecessary. The result matches JS whenever the server sends compact JSON, as in `errors.test.ts:92-95` (§12 q17).

Retry-After on a 429 uses the same parser as §5 (`errors.ts:92-95`, `reliability.test.ts:537-554`).

## 7. Logging

Levels are `debug < info < warn < error < off`, with `warn` as the default (`logging.ts:5-7,34-47`). The SDK only ever logs at `info` and `debug` (`client.ts` has no warn or error calls; `logging.test.ts:133-152`), so the default level is silent (`logging.test.ts:25-34`).

**info** lines, each prefixed with the tag `#<n> <METHOD> <path>` (`client.ts:340`):
- `<- <status> in <ms>ms` plus ` (request <id>)` when an id is present (`client.ts:390-392`)
- `retrying in <d>ms (retry <n>/<total>) after <status|error message>` (`client.ts:462`)
- `timed out after <ms>ms`, `connection error after <ms>ms` (with the cause as an extra argument), `aborted by caller …` (`client.ts:432-439`)

**debug** lines:
- `-> <url>` with `%{headers: redacted, body: request_body}` (`client.ts:368-371`)
- `<- body`, with the parsed body (`client.ts:344`)
- `<- error body` (`client.ts:396`)

**Redaction** (`logging.ts:53-79`):
- `authorization`, `proxy-authorization`, `x-api-key` → keep the scheme, then `***` plus the last 4 characters when the secret is longer than 8 (`Bearer ***cdef`). A short secret becomes `Bearer ***`.
- `cookie`, `set-cookie` → `***`
- Bodies are never redacted (`types.ts:233`).

The raw key must never appear in any log (`logging.test.ts:116-120`).

**Elixir mapping.**
- Emit through `Logger` with metadata `typesafe_request: n`.
- Gate calls on the client's `log_level` first; `:off` means no calls at all.
- `n` comes from `System.unique_integer([:positive, :monotonic])`. A client struct is immutable and cannot hold JS's per-client counter (`client.ts:257`), so tests match `#\d+`.
- Accept `"warn"` and `"warning"` (§12).
- `config :logger, level: :none` stays in `test.exs`. **Decision: ship a `logger:` option**, a function `(level, message, metadata) -> any` that defaults to calling `Logger.log/3`. It ports the JS `logger` option (`types.ts:237`). Tests pass `fn level, msg, meta -> send(test_pid, {:log, level, msg, meta}) end`.
  - Reason: `ExUnit.CaptureLog` cannot observe logs under a global `:none`. verified: with `Logger.configure(level: :none)`, `capture_log([level: :debug], fn -> Logger.info(...) end)` returned `""`, both alone and after `Logger.put_process_level(self(), :debug)`.

## 8. Question helpers

Exact wire output (`questions.ts:22-63`, `client.test.ts:262-322`, `client.test.ts:324-395`):

| Call | Output map (atom keys, Jason-encoded) |
|---|---|
| `noul()` | `%{type: "noul", instructions: nil}`. The criteria key is **omitted** (`client.test.ts:344,353`). |
| `noul(i)` | `%{type: "noul", instructions: i}`, criteria omitted (`client.test.ts:236,279`) |
| `noul(i, c)` | `%{type: "noul", instructions: i, criteria: c}`. `c` may be `nil`, which is sent as `null` (`client.test.ts:329`). Either or both of `true`/`false` may be present (`client.test.ts:278-287`). |
| `choice(i, criteria_map)` | `%{type: "choice", instructions: i, criteria: map}`, passed through without rewriting. A list is rejected (`questions.ts:59-61`, `client.test.ts:271-276`). |
| `score(i, criteria_list)` | `%{type: "score", instructions: i, criteria: list}`, passed through. A map is rejected; JS throws `TypeSafeError` with the message `"Score criteria must be a list of descriptions indexed by score from zero, not a map."` (`questions.ts:41-45`). This message is JS-only — per the "Builder shape errors" bullet below, the Elixir builder uses a guard clause and raises `FunctionClauseError` instead, with no custom message. |

- Descriptions and instructions may be a string, a JSON-able map or list, or nil (`types.ts:11,17-18`, `client.test.ts:289-294`). This conflicts with the docs (§12).
- Builder shape errors: use guard clauses (`is_map`/`is_list`), so bad input raises `FunctionClauseError`. That is a programmer error and matches the JS runtime throw.
- Callers may also pass raw question maps (`client.test.ts:337-356`).

**Request shape contract (§12 q12, RESOLVED — operator decision, Gate 4 review N5).** `system_one/3`'s `request` is atom-keyed: `%{state: term(), questions: %{atom() => question}, ...extra}`, matching the signature at §2 (`TypeSafe.system_one(client, %{state:, questions:} = request, opts)`). A request missing `:state`, or a string-keyed request map (e.g. one decoded straight from JSON), is a caller error and returns `{:error, %TypeSafe.Error{}}` with **zero** HTTP calls — it does not raise `FunctionClauseError`, and it is not normalized. This is a deliberate deviation from JS: JS forwards a request object structurally, so a missing `state` key sends `"state":undefined`, which `JSON.stringify` drops from the wire body entirely rather than erroring. The Elixir port requires the field.

**Pre-send validation in `system_one/3`** (`questions.ts:70-89`). Each failure returns `{:error, %TypeSafe.Error{}}` and makes **zero** HTTP calls (`client.test.ts:377-395`):
- empty questions → `"At least one question is required."`
- a score whose criteria is not a list → `Score question "q" has criteria that are not a list; …`
- fewer than 2 criteria → `Score question "q" has <n> criteria; at least two scores are required.`
- a score question with no `criteria` key at all (atom- or string-keyed) → an error, the same as non-list criteria (`questions.ts:75`, Gate 4 review B4)

**Answers** come back as the decoded JSON map with string keys, `result["answers"]["q"]["choice"]`. TypeScript's inference of answer types (`types.ts:117-142`, `test/types.test-d.ts`) has **no Elixir equivalent, and none is built**. Elixir provides `@type` specs for documentation only. There are no answer structs and no typed-accessor maps like Python's `nouls` / `choices` / `scores` (`sdk/python/api/types/responses.md:L160-L276`).

## 9. Deliberately NOT ported

| JS feature | Why / Elixir replacement |
|---|---|
| `APIPromise` lazy/eager thenable, `.map`, `.asResponse` (`api-promise.ts`) | Elixir calls are synchronous. `with_response: true` returns data, the `%Req.Response{}`, and `request_id`. Callers wanting async use `Task`. |
| `AbortSignal` / `APIUserAbortError` (`client.ts:413-417,450-469`) | No signal primitive exists. Cancel by killing the calling `Task`. |
| Browser guard, `dangerouslyAllowBrowser` (`client.ts:60-65,268`) | The BEAM is never a browser page. |
| Runtime detection (`runtime.ts`) | Replaced by a fixed Elixir/OTP string in `X-TypeSafe-Runtime` (§12). |
| Custom `fetch` and the global-fetch receiver fix (`client.ts:54-68,281-282`) | Replaced by `req_options`; tests use a Req module adapter (§11). |
| `bufferResponse` stalled-body abort (`client.ts:180-201`, `native-transport.test.ts`, `release-regressions.test.ts:85-146`) | Req/Finch read the full body. `receive_timeout` bounds stalls per recv (§12). |
| `__proto__` question preservation (`release-regressions.test.ts:72-83`) | A JS object-prototype hazard that Elixir maps do not have. |
| Policy mutation isolation (`reliability.test.ts:201-247`) | Elixir data is immutable, so there is nothing to test. |
| ESM/CJS/JSR packaging, tsdown, dist tests (`test/dist/*`, `jsr.json`) | Hex package instead. |
| Type-level tests (`test/types.test-d.ts`) | No type inference to test. Dialyzer specs are optional. |
| `ENV` constant as a runtime value | Documented only. |

## 9a. Stdlib / Req mapping and dependency flags

Runtime dependency: `req` only.

| Concern | Mechanism (stdlib or Req built-in) | Cite / evidence |
|---|---|---|
| HTTP transport, base URL, headers | `Req.new/1`, `Req.request/2`, `Req.Request.put_header/3` (names are downcased) | `req@0.7.4 lib/req/fields.ex` `put/3` |
| Option key validation | `Keyword.validate/2`. Value checks are guards; never NimbleOptions (transitive only) | verified (§4) |
| Request JSON encoding | Req `:json` option; never call Jason directly | `steps.ex:489-492` |
| Response JSON decoding | `decode_body: false` plus stdlib `JSON.decode/1` (Elixir ≥ 1.18; `mise.toml` pins 1.19.5), because Req's default decoder cannot parse JSON sent without a content-type | §3; verified |
| Retries | Req `:retry` (2-arity function returning `{:delay, ms}` / `false`), `:max_retries`, `retry_log_level: false`. `:retry_delay` is deliberately unused. | §5 (`steps.ex:1693-1700,1753,1826-1828`) |
| Retry-count header | Request step added with `Req.Request.append_request_steps/2`, reading `Req.Request.get_private(req, :req_retry_count, 0)` | `steps.ex:1808`; verified |
| Jitter | `:rand.uniform/0` | OTP `rand` |
| Retry-After HTTP date | `:httpd_util.convert_request_date/1` (OTP inets) plus `NaiveDateTime`/`DateTime` | verified |
| Retry-After number | `Integer.parse/1` / `Float.parse/1` | stdlib |
| Env vars | `System.get_env/1`, injected as the `:get_env` function option | §3 |
| Logging | `Logger.log/3` behind the `logger:` function option | §7; verified |
| Errors | `defexception` structs under `TypeSafe.Error.*` | §6 |
| Timeouts | Req `:receive_timeout`. `:pool_timeout` is not set at top level (deprecated, `req.ex:550-552`). | §5 |
| Request log tag | `System.unique_integer([:positive, :monotonic])` | §7 |
| Runtime header | `System.version/0`, `:erlang.system_info(:otp_release)` | §12 q14 |
| Version | `Application.spec(:typesafe_sdk_ex, :vsn)` | §2 |
| Test HTTP stubs | Req module adapter plus closure in `request.private`; state via `send/2` or `Agent` | §11; verified |

**JS features whose obvious port would add a dependency:**

| JS feature | Tempting dep | Resolution |
|---|---|---|
| `mockFetch` test helper (`test/helpers.ts:10-21`) | `plug` for `Req.Test`, or Mox | Req module adapter (§11). `Req.Test.json/2` and `transport_error/2` require `Plug.Conn` (`req@0.7.4 lib/req/test.ex:417-419`), and the `:plug` option routes through the `Req.Plug` adapter (`req.ex:604`). |
| Fake timers `vi.useFakeTimers` (`reliability.test.ts:43`) | a clock/mock library | Not ported. Delays are pure functions with `now` and `random` passed in, and end-to-end tests use zero delay (§5). |
| Option schema (`client.ts:70-147`) | NimbleOptions | `Keyword.validate/2` plus guards |
| JSON parse/stringify | Jason (direct) | Req `:json` for encoding, stdlib `JSON` for decoding, original body text for error messages (§6) |
| `Date.parse` for Retry-After (`retry.ts:46`) | Timex or a date library | `:httpd_util` (OTP) |
| TypeDoc API docs (`docs/typedoc.json`) | `ex_doc` | Not ported. Docs stay as `@moduledoc`/`@doc`, readable with `h/1` in IEx. |
| Runtime detection (`runtime.ts`) | none | stdlib (above) |
| `AbortSignal` cancellation | none | Not ported (§9) |

## 10. Slices (dependency order)

**S1: client config, transport, happy paths.** Depends on nothing. `TypeSafe.new/1`, `%TypeSafe.Client{}`, `%TypeSafe.RetryPolicy{}` defaults, `system_one/3`, `list_models/2`, headers, body parsing, `with_response`.
AC:
- (1) Precedence is option, then `:env`, then default for all 4 settings. Blank env counts as unset. A missing key returns `{:error, %TypeSafe.Error{}}` naming `TYPESAFE_API_KEY`.
- (2) The base URL has trailing slashes stripped.
- (3) The request carries the `Authorization`, `Accept`, `User-Agent`, `X-TypeSafe-SDK`, and `X-TypeSafe-Runtime` headers. Default and per-call headers merge, and callers cannot override protected headers. `Content-Type` is present only on POST.
- (4) `system_one` POSTs `/v1/systemone` with the request map plus `model`, where the explicit model wins over the client default, and forwards extra keys. It returns `{:ok, decoded_map}`.
- (5) `list_models` GETs `/v1/models` and returns `{:ok, list}`, keeping unknown fields.
- (6) `with_response: true` exposes `request_id` and the response.
- (7) `inspect(client)` does not contain the API key.

**S2: error mapping.** Depends on S1. §6 structs, messages, `request_id`, `retry_after_ms`, text and empty bodies, transport error wrapping, and the bad `/v1/models` shape. The tests run with `max_retries: 0`.
AC: every row in the §6 table is covered by at least one test, and each message rule in §6 is asserted verbatim.

**S3: retries and timeouts.** Depends on S2. Pure `TypeSafe.Retry` functions plus Req wiring (`decide/2`, `max_retries`, retry-count request step), per-call overrides, timeout mapping, and validation of retry and timeout values.
AC:
- (1) Exact §5 delay values come from the pure functions.
- (2) End-to-end attempt counts are correct for retryable and non-retryable statuses, for connection and timeout errors with each flag toggled, and for per-call overrides.
- (3) `X-TypeSafe-Retry-Count` is absent, then 1, then 2.
- (4) No test calls `Process.sleep` with a delay above 0. The suite for this slice runs in under 2s.

**S4: question helpers and pre-send validation.** Depends on S1; it can run in parallel with S2 and S3. §8 builders, wire preservation of nil, lists, and omitted keys, and validation with zero requests.
AC: every §8 row and validation message is asserted, and the stub adapter receives 0 calls on validation failure (`refute_received {:sent, _}`).

**S5: logging.** Depends on S3, because the retry lines exist only after S3. §7 levels, lines, redaction, and log-level validation.
AC:
- (1) Nothing is emitted at the default level or at `:off`.
- (2) The info summary and retry lines match the §7 formats.
- (3) Debug output includes redacted headers and bodies.
- (4) The raw API key never appears.
- (5) An invalid level names its source.

## 11. Ordered test list

Conventions for every test file:
- `use ExUnit.Case, async: true`.
- **HTTP stub seam.** There is no `plug`, `Req.Test`, or Mox. A test-support module `TypeSafe.StubAdapter` lives in `test/support/stub_adapter.ex`, which needs `elixirc_paths(:test)` in `mix.exs`:
  ```elixir
  def run(request), do: Req.Request.get_private(request, :typesafe_stub).(request)
  ```
  - A test builds the client with `{:ok, client} = TypeSafe.new(api_key: "k", req_options: [adapter: TypeSafe.StubAdapter], ...)` and then installs the closure with `client = %{client | req: Req.Request.put_private(client.req, :typesafe_stub, stub)}`. A helper `StubAdapter.client(stub, opts)` may wrap those two steps.
  - The stub is `fn request -> {request, Req.Response.new(status: 200, headers: [{"content-type", "application/json"}], body: ~s(...))} end`, or `{request, Req.TransportError.exception(reason: :timeout | :closed)}` for transport failures.
  - **Use a module, not a function adapter.** Req 0.7.4 prints a deprecation warning on stderr for every function adapter (`request.ex:1066-1069`). verified: the warning text is "setting `adapter` to a function is deprecated in favour of setting it to a module". That would break the clean-test-output rule.
  - The closure lives in the request's private map, so there is no global or process-dictionary state and the stub is async-safe. Private data survives retries, which reuse the same request struct (`steps.ex:1816-1817`).
  - Because the adapter runs inside Req's retry loop, S3 tests exercise real Req retries (§5, verified).
- **Stateful stubs.** A retry sequence such as `[503, 503, 200]` comes from `Agent.get_and_update/2` inside the closure; the test starts it with `start_supervised({Agent, fn -> [...] end})`, so ExUnit stops it. Captured requests go out with `send(test_pid, {:sent, request})`, and tests assert with `assert_received` / `refute_received`. At adapter time `request.body` is iodata, not a binary. Decode it with `JSON.decode(IO.iodata_to_binary(request.body))` and read headers with `Req.Request.get_header/2`. verified: `{:ok, %{"questions" => ..., "state" => nil}}` and `["application/json"]`.
- **Req's default `user-agent` is `["req/0.7.4"]`.** verified at the adapter. The client must set its own value (§3), and an S1 test asserts it.
- **Env.** Env comes from `new(get_env: fn name -> Map.get(env, name) end)`. There is no `System.put_env` and no `Application.put_env`.
- **Logs.** Logs come from `new(logger: fn level, msg, meta -> send(test_pid, {:log, level, msg, meta}) end)` (§7).
- No bang functions: use `{:ok, _} = ...`. No real network. No sleeps (§5 seam).

### S1 — `test/typesafe/client_test.exs`
1. `new/1 without api_key or env returns error naming TYPESAFE_API_KEY`: `{:error, %TypeSafe.Error{message: m}}`, and `m =~ "TYPESAFE_API_KEY"` (`client.test.ts:100-103`)
2. `new/1 falls back to defaults`: base_url, default_model `jev-latest`, log_level `:warning`, the default retry policy, and timeout 10_000 (`client.test.ts:44-51`)
3. `new/1 reads every setting from env` (`client.test.ts:53-63`)
4. `new/1 prefers options over env` (`client.test.ts:65-80`)
5. `new/1 treats blank and whitespace env values as unset` (`client.test.ts:89-98`)
6. `new/1 strips trailing slashes from base_url in option and env` (`client.test.ts:105-111`)
7. `inspect(client) never contains the api key` (`client.test.ts:82-87`)
8. `list_models sends auth and identifying headers`: GET to `https://x.test/v1/models`, `authorization: Bearer secret`, `user-agent`/`x-typesafe-sdk` match `typesafe-sdk…/<version>`, `x-typesafe-runtime` present, no `content-type` (`client.test.ts:131-147`)
9. `list_models unwraps models`: an empty list and a one-card list (`client.test.ts:164-174`)
10. `list_models preserves unknown model fields` (`client.test.ts:187-195`)
11. `system_one posts payload with default model and returns decoded body`: exact wire body, and `answers["q1"]["noul"] == 0.5` (`client.test.ts:197-210`)
12. `system_one: explicit model wins, client default_model otherwise` (`client.test.ts:212-234`)
13. `system_one forwards extra top-level keys including nil` (`client.test.ts:413-426`)
14. `headers: default and per-call merge, per-call wins, authorization protected` (`client.test.ts:149-162`)
15. `headers: case-insensitive override attempts cannot change protected headers; content-type is application/json on POST` (`release-regressions.test.ts:15-58`; the retry-count part is in S3)
16. `GET strips caller content-type and retry-count headers` (`release-regressions.test.ts:60-70`)
17. `with_response: true returns data, response status 200, request_id` (`client.test.ts:398-411`, `api-promise.test.ts:21-32`)
18. `with_response: request_id is nil without header` (`api-promise.test.ts:34-39`)
19. `body parsing: JSON without content-type is decoded` (`errors.test.ts:127-133`, success-path variant: new)
20. `body parsing: system_one on 204 empty body returns {:ok, nil}` (`release-regressions.test.ts:148-153`, adapted)

### S2 — `test/typesafe/error_test.exs`
1. `maps status to struct`, parameterized over 400, 401, 403, 404, 422, 429, 500, 503, 529, 418 (`errors.test.ts:20-40`; 529 is new, from `api.md:L319`)
2. `every API error carries status, body, headers, request_id` (`errors.test.ts:43-57`)
3. `message: error.message` → `"401 invalid api key"` (`errors.test.ts:43-57`)
4. `message extraction`, parameterized: `error` string, `message`, `detail` string, `detail.message`, `detail` list → `"questions.q.score.criteria: Input should be a valid list; questions: Dictionary should have at least 1 item"` (`errors.test.ts:59-89`)
5. `message falls back to raw JSON` → `400 {"code":7}` (`errors.test.ts:91-95`)
6. `raw fallback truncates to 200 chars plus …` (`errors.test.ts:97-101`)
7. `non-JSON body kept as text`: a 502 HTML body gives `InternalServer` with body and message (`errors.test.ts:104-115`)
8. `empty body` → `"429 status code (no body)"`, body nil (`errors.test.ts:117-125`)
9. `rate limit exposes retry_after_ms` → 7000 (`reliability.test.ts:538-545`)
10. `rate limit retry_after_ms nil when header absent` (`reliability.test.ts:547-553`)
11. `transport :closed` → `%Connection{}` with the reason kept, and the message contains the cause (`client.test.ts:249-259`)
12. `transport :timeout` → `%Timeout{timeout_ms: t, message: "Request timed out after <t>ms."}` (`reliability.test.ts:445-458`)
13. `list_models unexpected shape returns TypeSafe.Error`, parameterized over `nil`, `[]`, `{"models":{"models":[]}}`, `{"models":null}`, `{"models":"bad"}`, `{"ok":true}` (`client.test.ts:176-185`)

### S3 — `test/typesafe/retry_test.exs` (pure) and `test/typesafe/reliability_test.exs` (stubbed)
Pure:
1. `default policy values and status set` (`retry.test.ts:17-36`)
2. `retryable statuses by default`: 408, 429, 500, 502, 503, 504, 529, 599 → true; 200, 400, 401, 403, 404, 409, 422, 600 → false (`retry.test.ts:38-44`)
3. `custom and empty http_statuses` (`retry.test.ts:46-51`)
4. `parse_retry_after seconds`: "3" → 3000, "0" → 0, "1.5" → 1500 (`retry.test.ts:55-59`)
5. `retry-after-ms preferred` (`retry.test.ts:61-63`)
6. `HTTP date relative to injected now; past → 0` (`retry.test.ts:65-69`)
7. `missing/garbage/negative → nil` (`retry.test.ts:71-76`)
8. `delay_ms exponential 500..5000 with zero jitter` (`retry.test.ts:84-88`)
9. `jitter shaves at most fraction` → 375, 875 (`retry.test.ts:90-93`)
10. `Retry-After honored exactly without jitter` (`retry.test.ts:95-98`)
11. `Retry-After over ceiling falls back to backoff`: 61s → 500, 60s → 60000, ms 60001 → 375 (`retry.test.ts:100-105`)
12. `policy initial/cap/jitter respected` (`retry.test.ts:107-114`)
13. `respect_retry_after false ignores header` (`retry.test.ts:116-119`)
14. `max_retry_after_ms ceiling` (`retry.test.ts:121-125`)
15. `decide/2 returns {:delay, 2000} for 429 with retry-after 2 and false for 400`: a direct call with a built request and response, no HTTP (new)
16. `validation names each bad field`: max_retries -1 and 1.5, backoff_initial_ms -1, backoff_jitter 1.5 and -0.1, http_statuses containing 42, zeros accepted, jitter 1 accepted (`reliability.test.ts:168-180,402-421`; the NaN and ±Infinity cases are not representable)

Stubbed (every client uses zero backoff):
17. `429 then 200 succeeds, 2 requests` (`reliability.test.ts:51-73`, using `retry-after-ms: 0` in place of `retry-after: 2`)
18. `503, 503, 200 succeeds after 3 requests` (`reliability.test.ts:75-92`)
19. `gives up after max_retries and returns last error`: max 3 → 4 requests, `InternalServer` (`reliability.test.ts:94-99`)
20. `400 not retried`: 1 request (`reliability.test.ts:101-106`)
21. `POST system_one retries 503` (new: guards against Req's `:safe_transient` GET-only default)
22. `connection error retried then succeeds` (`reliability.test.ts:108-117`)
23. `per-call max_retries 0 overrides client 5` (`reliability.test.ts:144-151`)
24. `per-call retry override merges field by field and leaves client policy unchanged` (`reliability.test.ts:383-400`; the log-line assertion moves to S5)
25. `X-TypeSafe-Retry-Count absent, "1", "2"` (`reliability.test.ts:153-166`)
26. `caller-supplied retry-count removed on every attempt` (`release-regressions.test.ts:15-58`, retry-count part)
27. `only statuses in http_statuses retried`: 409 retried with a custom set, 503 not retried with an empty set (`reliability.test.ts:260-278`)
28. `api_connection_error false stops connection retries, timeouts still retried` (`reliability.test.ts:280-308`)
29. `api_timeout_error false stops timeout retries, connection still retried` (`reliability.test.ts:310-338`)
30. `respect_retry_after false with zero backoff still retries` (`reliability.test.ts:362-381`, delay-free variant)
31. `per-call timeout is passed as receive_timeout`: assert on the built Req request, no stall (`reliability.test.ts:493-505`, adapted)
32. `invalid timeout from option or per call returns error before any request` (`reliability.test.ts:524-534`)
33. `invalid per-call retry returns error before any request` (`reliability.test.ts:176-180,414-421`)

### S4 — `test/typesafe/questions_test.exs`
1. `noul/0 → instructions nil, no criteria key` (`client.test.ts:344,353`)
2. `noul/1 omits criteria` (`client.test.ts:278-279`)
3. `noul/2 one side, both, nil` (`client.test.ts:278-287,329`)
4. `choice passes criteria map untouched` (`client.test.ts:263-269`)
5. `choice with list raises FunctionClauseError` (`client.test.ts:271-276`)
6. `score keeps list; map raises` (`client.test.ts:315-321`)
7. `descriptions may be maps/lists` (`client.test.ts:289-294`)
8. `wire preserves nil state, instructions, criteria` (`client.test.ts:325-335`)
9. `wire allows omitted instructions and nested lists; raw question maps accepted` (`client.test.ts:337-356`)
10. `choice and score criteria sent without rewriting` (`client.test.ts:367-375`)
11. `choice answer decoded with winning label` (`client.test.ts:296-313`)
12. `empty questions → error "At least one question is required", 0 requests` (`client.test.ts:377-395`)
13. `score criteria map → error naming question, 0 requests` (same)
14. `score criteria [] and ["only"] → "has 0 criteria; at least two scores are required.", 0 requests` (same)

### S5 — `test/typesafe/logging_test.exs`
1. `default level emits nothing on success` (`logging.test.ts:25-34`)
2. `:off emits nothing` (`logging.test.ts:79-83`)
3. `invalid level from env names TYPESAFE_LOG_LEVEL and lists levels; from option names the option` (`client.test.ts:119-128`)
4. `every level accepted from option and env` (`client.test.ts:113-117`)
5. `info: one summary line "#N GET /v1/models <- 200 in Xms (request req_9)", nothing at debug` (`logging.test.ts:85-92`)
6. `info: retry line "retrying in 0ms (retry 1/2) after 429"` (`reliability.test.ts:51-73`, zero-delay variant)
7. `info: per-call retry total reflected "(retry 1/1)"` (`reliability.test.ts:383-400`)
8. `debug: request line with redacted headers and nil body, then "<- body"` (`logging.test.ts:94-114`)
9. `error response: info summary plus debug "<- error body", no warning or error` (`logging.test.ts:133-152`)
10. `connection error logged at info with cause` (`logging.test.ts:154-170`)
11. `raw api key never logged at debug` (`logging.test.ts:116-120`)
12. `concurrent requests carry distinct tags` (`logging.test.ts:122-131`)
13. `redact: scheme kept, last 4 of long secret; cookie fully masked; other headers untouched` (`logging.test.ts:192-206`)
14. `redact: short secret has no tail` (`logging.test.ts:208-210`)

## 12. Open questions and ambiguities

**Docs vs JS source.** Record both sides; the planner does not choose silently.
1. **`instructions` required?** `api.md:L64,L105,L143` and `primitives/noul.md:L253` mark it required. JS makes it optional or null (`types.ts:24,43,55`; `noul()` default `null` at `questions.ts:23`; sent omitted at `client.test.ts:337-356`). The spec follows JS, so the SDK does not validate it. The live API's behavior is unverified.
2. **`state: null`.** `api.md:L23` gives `string | object | array`, required. JS allows `null` (`types.ts:162`, `client.test.ts:325-335`).
3. **Description types.** `api.md:L72-L76` types noul `true`/`false` as strings, and `api.md:L109` types choice criteria as `string | null`. `primitives/choice.md:L314` and JS (`types.ts:11,17-31`) allow string, object, or array. The docs contradict each other; the spec follows JS.
4. **Level and option bounds.** Score takes 2 to 10 levels (`primitives/score.md:L272`) and choice takes up to 255 options (`primitives/choice.md:L355`). JS checks only `>= 2` for score (`questions.ts:82`) and nothing for choice. The Python client documents only "criteria list is empty" (`sdk/python/api/clients/sync/client.md`, system_one Raises). The spec follows JS, so upper bounds are left to the server's 422.
5. **Error statuses.** `api.md:L314-L319` lists only 401, 422, 429, and 529. JS maps 400, 403, and 404 as well, and the live test expects a 400 `"400 Unknown model: no-such-model"` (`test/integration/api.integration.ts:116-127`).
6. **`GET /v1/models`** is documented in `models.md:L38-L83` and missing from `api.md`.
7. **`legend` value type.** `api.md:L276` says `map<string,string>`. JS types values as the original descriptions (`types.ts:98-100`), and Python allows `str | dict | list` (`sdk/python/api/types/responses.md`, ScoreAnswer.legend).
8. **Retry-After.** `models.md:L17` says SDKs "honor the `retry-after` header". JS also reads `retry-after-ms` (`retry.ts:38-40`).

**JS vs Python SDK.** Python is the second reference implementation.

9. **Total retry budget.** Python `RetryPolicy.timeout = 30.0`s total (`sdk/python/api/retries.md:L428-L430`). JS has none (`types.ts:200`). Python also has `exceptions` and `predicate` (`retries.md:L364,L376`), which JS rejects (`test/types.test-d.ts:132-133`). The spec follows JS.
10. **Response validation.** Python raises `TypeSafeAPIResponseValidationError` with `field_path` (`sdk/python/api/exceptions.md:L254-L272`). JS returns unvalidated JSON except for `/v1/models`. The spec follows JS (restraint).
11. **Log levels and redaction.** Python uses `warning` and defaults to unset (`sdk/python/usage.md`, Logging and Env table). JS uses `warn` (`logging.ts:5-7`). Python redacts any header whose name contains `token` or `secret`; JS redacts a fixed list (`logging.ts:54-61`). Elixir `Logger` says `:warning`. Proposal: accept `"warn"` and `"warning"`, and keep JS's redaction list.
12. **API shape. RESOLVED — operator decision.** Python uses `system_one(state, questions, *, model, retry, timeout, extra_headers, extra_body)` and groups responses as `nouls` / `choices` / `scores` (`sdk/python/api/clients/sync/client.md`). JS uses a request object with spread extras. Elixir uses `system_one(client, %{state:, questions:} = request, opts \\ [])`, staying closest to the JS tests. See §8 "Request shape contract" for the atom-keyed, `:state`-required consequence of this decision.

**Unresolved from source.**

13. **Timeout semantics.** JS bounds headers plus the full body per attempt (`client.ts:403-447`). Req `receive_timeout` is a socket-receive timeout (`req@0.7.4 lib/req.ex:445`), so a server that trickles its body can exceed the total. Is that acceptable, or does the port need a `Task.await`-bounded attempt?
14. **`User-Agent` / `X-TypeSafe-SDK` / `X-TypeSafe-Runtime` values** for the Elixir SDK. Options are `typesafe-sdk/<ex-version>` or `typesafe-sdk-ex/<version>`, and `elixir/<System.version()> (otp/<release>)`. Whether the server parses these is unknown.
15. **Retry-After number parsing.** JS `Number()` accepts `"0x10"`, `"1e3"`, and whitespace (`retry.ts:44`). Proposal: support non-negative decimals only.
16. **Explicit empty `api_key: ""`. RESOLVED — operator decision (Gate 4 review N7).** JS accepts it, because `??` falls back only on null/undefined (`env.ts:22-23`), and then sends `Bearer `. The Elixir port does NOT mirror that: an explicit blank or whitespace-only `api_key` option (`""`, `"   "`) is rejected with the same `{:error, %TypeSafe.Error{message: m}}` (`m =~ "TYPESAFE_API_KEY"`) as a blank environment value — an explicit blank is treated identically to "not given," not as "given but empty."
17. **Raw-body error message.** JS re-stringifies the parsed body (`errors.ts:64`); Elixir uses the original text (§6). The two differ only when the server sends non-compact JSON. Is that acceptable?
18. **`:inets` in releases.** `:httpd_util` works in `mix`/`elixir` without starting inets (verified). Whether a release needs `:inets` in `extra_applications` to bundle it requires verification in a release build. Resolved from the earlier draft: log capture now goes through the `logger:` option (§7, verified), and the HTTP-date parser is `:httpd_util` (§5, verified).
19. **Request-tag numbering.** JS `#1` is per client. Elixir uses a VM-wide monotonic integer. Is that acceptable?

## 13. Integration test plan (deferred)

Not part of any slice, and it never runs in `mise run ci`.

- **Location:** `test_live/typesafe_live_test.exs`. It sits outside `test_paths`, so `mix test` never compiles it. That is a structural exclusion rather than an `:integration` tag.
- **Runner:** a separate mise task `test:live` → `mix test test_live`. The task fails fast when `TYPESAFE_API_KEY` is unset, and supplies the key through 1Password (`op run`). It is not a dependency of `ci`.
- **Calls and assertions**, derived from `test/integration/api.integration.ts:25-147`:
  1. `list_models(with_response: true)`: non-empty list, each `name`/`description`/`release_date` a string, `request_id =~ ~r/^req_/`.
  2. `system_one` with the ticket state plus noul, choice (calm/frustrated/angry), and score (3 levels):
     - `usage.input_tokens > 0`
     - noul in 0..1
     - choice label within the options, probability keys equal to the options, probabilities summing to ≈1 (1 dp)
     - score in 0..2, `legend == %{"0"=>…, "1"=>…, "2"=>…}`, probability keys `["0","1","2"]`
  3. Rich (map) descriptions and a one-sided noul criteria are accepted.
  4. A bad key with `max_retries: 0` gives `%Authentication{}`.
  5. `model: "no-such-model"` gives `%BadRequest{message: "400 Unknown model: no-such-model"}` with `request_id`. This resolves open question 5 against the live API.
  6. A score with a numeric criterion gives `%UnprocessableEntity{}` with message `=~ ~r/^422 questions\.q\.score\.criteria\.0/`.
  7. Additional probes for open questions 1, 2, and 4: omitted `instructions`, `state: nil`, and an 11-level score. Record the observed status; assert nothing until the behavior is decided.
- **Timeout:** 120_000 ms, from `api.integration.ts:26`. Logging at `:info`.
