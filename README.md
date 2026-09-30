# typesafe ai sdk 

typesafeai sdk in elixir using req based on:

https://github.com/typesafe-ai/typesafe-sdk-js

## Usage

Set `TYPESAFE_API_KEY` in your environment, then create and use the client:

```elixir
{:ok, client} = TypeSafe.new()

{:ok, response} =
  TypeSafe.system_one(client, %{
    state: %{document: "I was charged twice. Please fix this ASAP."},
    questions: %{
      category: TypeSafe.choice("What is this ticket about?", %{billing: nil, technical: nil, other: nil})
    }
  })

response["answers"]["category"]["choice"]
```

`TypeSafe.new/1` also accepts `api_key:`, `base_url:`, `default_model:`, and
`log_level:` options, each falling back to its `TYPESAFE_*` environment
variable and then a default — see the `@doc` on `TypeSafe.new/1`.

Question helpers `TypeSafe.noul/0,1,2`, `TypeSafe.choice/2`, and
`TypeSafe.score/2` build the typed questions passed to `system_one/3`.
`TypeSafe.list_models/2` lists available models.

## Errors

A non-2xx HTTP response from `system_one/3` or `list_models/2` returns a
status-mapped error struct under `TypeSafe.Error.*`:

- `TypeSafe.Error.BadRequest` (400)
- `TypeSafe.Error.Authentication` (401)
- `TypeSafe.Error.PermissionDenied` (403)
- `TypeSafe.Error.NotFound` (404)
- `TypeSafe.Error.UnprocessableEntity` (422)
- `TypeSafe.Error.RateLimit` (429, carries `retry_after_ms`)
- `TypeSafe.Error.InternalServer` (5xx, including 529)
- `TypeSafe.Error.API` (any other non-2xx status, e.g. 409 or 418)
- `TypeSafe.Error.Connection` (a transport failure — closed socket, DNS, TLS)
- `TypeSafe.Error.Timeout` (the configured timeout was exceeded)

The generic `TypeSafe.Error` still covers everything that isn't a mapped
HTTP failure: client-config problems from `new/1`, question-validation
failures from `system_one/3`, and an unexpected `/v1/models` response
shape.

There is **no shared base struct** — the ten `TypeSafe.Error.*` structs and
the generic `TypeSafe.Error` are unrelated exceptions. Match on `{:error,
exception}` for a catch-all clause; `Exception.message/1` works on all of
them:

```elixir
case TypeSafe.system_one(client, request) do
  {:ok, result} ->
    result

  {:error, %TypeSafe.Error.Authentication{} = error} ->
    {:error, "auth failed: " <> Exception.message(error)}

  {:error, %TypeSafe.Error.RateLimit{retry_after_ms: ms} = error} ->
    retry = if ms, do: " (retry after #{ms}ms)", else: ""
    {:error, "rate limited#{retry}: " <> Exception.message(error)}

  {:error, exception} ->
    {:error, Exception.message(exception)}
end
```

## Retries

By default a failed request is retried up to 2 times when it fails with a 408,
a 429, any 5xx status, or a connection error (a closed socket, DNS, TLS, and
similar). Retries wait with exponential backoff: 500ms, then 1000ms, capped at
5000ms, each shortened at random by up to 25% (jitter). A `Retry-After` or
`retry-after-ms` response header is honored exactly, without jitter, when the
value is at most `max_retry_after_ms` (60 seconds by default); a larger value
falls back to backoff. After the last retry the last error is returned, and a
2xx response is never retried.

**Timeouts are not retried by default.** A `POST /v1/systemone` that timed out
may already have been processed and billed, and the API has no idempotency key,
so a retry could run it twice. Opt in with `retry: [api_timeout_error: true]`.
A connection error that drops mid-response carries a smaller version of the
same risk; opt out with `retry: [api_connection_error: false]`, or turn
retries off entirely with `retry: [max_retries: 0]`.

Set the policy on the client, and override it per call. A per-call `retry:` is
merged field by field onto the client's policy and leaves the client unchanged:

```elixir
{:ok, client} = TypeSafe.new(retry: [max_retries: 5, backoff_initial_ms: 250])

# This call retries up to 5 times, and also retries timeouts.
{:ok, models} = TypeSafe.list_models(client, retry: [api_timeout_error: true])

# This call never retries.
{:ok, response} = TypeSafe.system_one(client, request, retry: [max_retries: 0])
```

The fields are `max_retries`, `backoff_initial_ms`, `backoff_max_ms`,
`backoff_jitter`, `http_statuses` (a list, `Range`, or `MapSet` of statuses
from 100 to 999), `respect_retry_after`, `max_retry_after_ms`,
`api_connection_error`, and `api_timeout_error`; see `TypeSafe.RetryPolicy`.
An invalid value, an unknown key, or `retry: nil` returns
`{:error, %TypeSafe.Error{}}` naming `retry.<field>`, before any request is
sent.

Every retry carries an `X-TypeSafe-Retry-Count` header with the retry number
(`"1"`, `"2"`, ...). The first attempt has no such header, and a value you set
yourself is removed.

`req_options` cannot set `retry_delay`, `max_retries`, or `retry_log_level`;
`new/1` returns an error naming the option.

### Known limitations

- **Fixed timeout.** Every request uses a fixed 10-second timeout; there is no
  client-level or per-call timeout option yet.
- **No logging.**
- **No telemetry.**

## Installation

This package is not on Hex — the name `typesafe_sdk` there belongs to a
different project. Install it as a git dependency:

```elixir
def deps do
  [
    {:typesafe_sdk_ex, github: "vinnie357/typesafe_sdk_ex"}
  ]
end
```

## Development

Tooling is managed via [mise](https://mise.jdx.dev/):

```sh
mise install
mise run ci
```

`mise run ci` runs the full local quality gate: compile with warnings as
errors, format check, `credo --strict`, the test suite, `mix hex.audit`,
and a gitleaks scan.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contribution workflow.
