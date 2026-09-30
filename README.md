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
- `TypeSafe.Error.Connection` (a transport failure — closed socket, DNS, TLS — or a
  busy connection pool, `reason: :pool_timeout`; see [Connection pool](#connection-pool))
- `TypeSafe.Error.Timeout` (the effective timeout was exceeded)

The generic `TypeSafe.Error` still covers everything that isn't a mapped
HTTP failure: client-config problems from `new/1`, question-validation
failures from `system_one/3` (including request content JSON cannot encode),
and an unexpected `/v1/models` response shape.

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
`max_retries` and the three millisecond fields (`backoff_initial_ms`,
`backoff_max_ms`, `max_retry_after_ms`) must be non-negative integers, and
`backoff_jitter` a number from 0 to 1.
An invalid value returns `{:error, %TypeSafe.Error{}}` naming the field
(`retry.max_retries must be a non-negative integer, got -1`), before any request
is sent. The other rejections use these messages: `retry must be a keyword list,
got nil` (for `retry: nil`), `retry has unknown option(s): bogus`, and
`retry.max_retries given more than once`.

Raising `max_retry_after_ms` has a cost: a server's `Retry-After` up to that
value makes one call sleep that long before it retries.

Every retry carries an `X-TypeSafe-Retry-Count` header with the retry number
(`"1"`, `"2"`, ...). The first attempt has no such header, and a value you set
yourself is removed.

`req_options` cannot set `retry_delay`, `max_retries`, or `retry_log_level`;
`new/1` returns an error naming the option. See [Request options](#request-options).

## Timeouts

Every request has a timeout of 10 seconds (10_000 ms) by default. Set another
value, in whole milliseconds, on the client with `timeout:`, and override it per
call on `TypeSafe.system_one/3` and `TypeSafe.list_models/2`. A per-call value
wins for that call and leaves the client unchanged:

```elixir
{:ok, client} = TypeSafe.new(timeout: 30_000)

# This call times out after 5 seconds.
{:ok, models} = TypeSafe.list_models(client, timeout: 5_000)
```

`timeout:` must be a positive integer of at most 4_294_967_295 (about 49.7
days). A float, `0`, a negative number, or `nil` returns `{:error,
%TypeSafe.Error{}}` (`timeout must be a positive integer, got nil`), and a larger
integer returns `timeout must be at most 4294967295 ms, got <n>`, both before any
request is sent. There is no environment-variable fallback.

The timeout applies to each attempt, not to the call as a whole: a retry gets a
fresh timeout, so a call with retries can take longer in total. It is passed to
Req as `receive_timeout`, which limits the wait for each read from the socket,
so a response that trickles in slowly can run past it.

**`timeout:` does not bound connecting.** Opening the connection uses Finch's
default of 5_000 ms. Change it with `req_options: [connect_options: [timeout:
ms]]`. When a request times out, whether while reading or while connecting, the
error is a `TypeSafe.Error.Timeout` whose `timeout_ms` is the configured
per-read `timeout:` for that call, not the time that elapsed, so a connect
timeout reports it too. A timeout is not retried unless you set
`retry: [api_timeout_error: true]`, and that also covers a connect timeout,
because Req reports both the same way.

`req_options` cannot set `receive_timeout` or `request_timeout`, at the top level
or under `finch:`; `new/1` returns an error naming the option. To bound waiting
for a free connection in the pool, use `req_options: [finch: [pool_timeout:
ms]]`. A top-level `pool_timeout` is rejected. `finch:` and `connect_options:`
cannot be combined, and `new/1` rejects the pair.

### Known limitations

- **No logging.**
- **No telemetry.**

## Connection pool

Requests share a Finch connection pool, and a request holds one connection for
its whole round trip. Req's default pool keeps up to 50 connections per host.
When more calls than that run at once, the extra calls wait for a free
connection for up to 5_000 ms (Finch's `pool_timeout`). If none frees up in
time, the call returns an error and sends nothing:

```elixir
{:error, %TypeSafe.Error.Connection{reason: :pool_timeout}} =
  TypeSafe.system_one(client, request)
```

The message is `Connection error: connection pool exhausted (no connection
available within the pool timeout)`. It is a `TypeSafe.Error.Connection`, not a
`TypeSafe.Error.Timeout`: `timeout:` limits reads from the socket and does not
cover this wait. The SDK does not retry it under any `retry:` policy, because a
retry would queue behind the same busy pool.

Under load, size the pool for the concurrency you run. `finch: [size: n]` makes
Req start a pool of `n` connections per host for those options, so this client
can run 200 calls at once against the API host:

```elixir
{:ok, client} = TypeSafe.new(req_options: [finch: [size: 200]])
```

To wait longer for a free connection instead, raise `pool_timeout:` (in
milliseconds):

```elixir
{:ok, client} = TypeSafe.new(req_options: [finch: [pool_timeout: 15_000]])
```

To share one pool across clients, or across your application, start a named
Finch pool in your supervision tree and point the client at it. Pool options
such as `size:` belong to the pool you start, and `new/1` rejects `finch:` with
`name:` and a pool option; `pool_timeout:` and `pool_tag:` may go with `name:`:

```elixir
children = [{Finch, name: MyApp.Finch, pools: %{default: [size: 200]}}]
{:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_one)

{:ok, client} =
  TypeSafe.new(req_options: [finch: [name: MyApp.Finch, pool_timeout: 15_000]])
```

## Request options

`req_options` passes transport settings to Req. `new/1` accepts only these
top-level keys: `adapter`, `connect_options`, `finch`, `finch_private`,
`headers`, `inet6`, and `unix_socket`. It also accepts `base_url`,
`decode_body`, `retry`, and `auth`, but the SDK overrides them: `base_url` is
the client's, `decode_body` and `retry` are `false`, and `auth` is dropped. Any
other key, such as `http_errors`, `url`, `json`, `body`, `params`, `plug`, or
`redirect`, makes `new/1` return `{:error, %TypeSafe.Error{}}` naming it.

- `finch:` takes a keyword list with the keys `name`, `pool_timeout`,
  `pool_tag`, `size`, `count`, `protocols`, `conn_opts`, `pool_max_idle_time`,
  `conn_max_idle_time`, `start_pool_metrics?`, and `http2`. A pool name given
  as an atom (`finch: MyApp.Finch`) is rejected; write `finch: [name:
  MyApp.Finch]`. `name:` cannot go with a pool option other than
  `pool_timeout` and `pool_tag`.
- `connect_options:` takes a keyword list with the keys `timeout`, `protocols`,
  `transport_opts`, `proxy`, `proxy_headers`, `hostname`, and
  `client_settings`. It cannot be combined with `finch:`.
- `headers:` takes a map or a list of `{name, value}` pairs. A name is a
  binary or an atom, and a value is a binary or a list of binaries; integer and
  `DateTime` values are rejected. The SDK's own `authorization` header wins over
  one you set here.

`new/1` checks keys and the shapes stated above, not values: a wrong-typed value
such as `finch: [size: :x]` or `adapter: 5` passes `new/1` and raises on the
first call. The check runs on Req's application config, `config :req,
:default_options`, with `req_options` merged over it. A key that `req_options`
sets replaces the whole value from that config, so a `finch:` in `req_options`
hides a `finch:` in the config, and neither is merged with the other. The last
of a repeated key wins. An entry in `config :req, :default_options` is validated
too, and the error names it as `config :req, :default_options`. When
`req_options` sets no `headers:`, every `headers:` entry in the config is
checked, because Req folds them all. `new/1` reads the config when it runs.

A `finch: [name: MyApp.Finch]` that names a pool you did not start raises
`ArgumentError` on the first call. That is a programming error, like sending a
message to a process that is not running.

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
