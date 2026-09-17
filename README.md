# typesafe ai sdk 

typesafeai sdk in elixir using req based on:

https://github.com/typesafe-ai/typesafe-sdk-js

## Development

Tooling is managed via [mise](https://mise.jdx.dev/):

```sh
mise install
mise run ci
```

`mise run ci` runs the full local quality gate: compile with warnings as
errors, format check, `credo --strict`, the test suite, and a gitleaks scan.
