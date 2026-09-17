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
    {:error, "rate limited (retry after #{ms}ms): " <> Exception.message(error)}

  {:error, exception} ->
    {:error, Exception.message(exception)}
end
```

### Known limitations

- **No retries.** A 429 or 503 response returns immediately; the caller is
  responsible for any retry loop. `Retry-After` is exposed only as
  `TypeSafe.Error.RateLimit.retry_after_ms`, and only when the header is an
  integer-seconds value — decimals, `retry-after-ms`, and HTTP-date values
  are not parsed.
- **No per-call timeout option.** Every request uses the client's
  configured timeout; there is no per-call override.
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
errors, format check, `credo --strict`, the test suite, and a gitleaks scan.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contribution workflow.
