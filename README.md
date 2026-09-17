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

Retries, timeouts, the full HTTP error taxonomy, and logging are still in
progress (tracked as later slices of the Elixir port) — `system_one/3` and
`list_models/2` currently treat any non-2xx response as a generic
`TypeSafe.Error`.

## Development

Tooling is managed via [mise](https://mise.jdx.dev/):

```sh
mise install
mise run ci
```

`mise run ci` runs the full local quality gate: compile with warnings as
errors, format check, `credo --strict`, the test suite, and a gitleaks scan.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contribution workflow.
