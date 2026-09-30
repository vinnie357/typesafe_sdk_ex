defmodule TypeSafe do
  @moduledoc """
  Elixir port of the TypeSafe AI SDK, built on Req.

  Configure a client with `new/1` (reading `TYPESAFE_API_KEY` and friends from
  the environment by default), then call `system_one/3` to ask typed questions
  about application state, or `list_models/2` to list available models.

  Build questions with `noul/0`, `noul/1`, `noul/2`, `choice/2`, and `score/2`.

  This module is a thin public facade over internal modules that handle
  option/env resolution, Req/HTTP mechanics, and question building.
  """

  @typedoc "Log level accepted by `new/1`'s `:log_level` option."
  @type log_level :: :debug | :info | :warning | :error | :off

  @typedoc "A `system_one/3` request: `state`, `questions`, and any extra top-level keys."
  @type request :: %{
          required(:state) => term(),
          required(:questions) => map(),
          optional(atom()) => term()
        }

  @typedoc "A question wire map built by `noul/0`, `noul/1`, `noul/2`, `choice/2`, or `score/2`."
  @type question :: map()

  @typedoc "Shape returned when a call is made with `with_response: true`."
  @type with_response_result :: %{
          data: term(),
          response: Req.Response.t(),
          request_id: String.t() | nil
        }

  @version Mix.Project.config()[:version]

  @doc """
  Returns the library's version string, as declared in `mix.exs`.

  Falls back to the version baked in at compile time when
  `Application.spec/2` returns `nil` (the application is not loaded, e.g. a
  bare `elixir -e` invocation).

  ## Examples

      iex> TypeSafe.version()
      "0.1.1"

  """
  @spec version() :: String.t()
  def version do
    case Application.spec(:typesafe_sdk_ex, :vsn) do
      nil -> @version
      vsn -> to_string(vsn)
    end
  end

  @doc """
  Builds a `TypeSafe.Client`.

  Resolves `:api_key`, `:base_url`, `:default_model`, and `:log_level` in this
  order: the option, then the matching `TYPESAFE_*` environment variable (read
  through `:get_env`, which defaults to `&System.get_env/1`), then a default.
  A `nil` option counts as not given and falls back to the environment. An
  explicit blank (empty or whitespace-only) `:api_key` option is rejected with
  `TYPESAFE_API_KEY is required.` even when `TYPESAFE_API_KEY` is set; a blank
  environment value counts as unset. The `:api_key` option and every environment
  value are trimmed of whitespace and of U+FEFF (the byte order mark), so a BOM-only
  value is blank and a BOM around a key is removed. A key given twice returns
  `{:error, %TypeSafe.Error{message: "<key> given more than once"}}`, for example
  `"timeout given more than once"`.

  Options:
  - `:api_key` — required unless `TYPESAFE_API_KEY` is set. Must be a string.
  - `:base_url` — default `https://api.typesafe.ai`. Must be a string; trailing slashes
    are stripped.
  - `:default_model` — default `jev-latest`. Must be a string.
  - `:log_level` — one of `t:log_level/0`, default `:warning`.
  - `:default_headers` — a map merged onto every request, default `%{}`.
  - `:req_options` — a keyword list of transport options for `Req.new/1`. Only these
    top-level keys are supported: `adapter`, `connect_options`, `finch`, `finch_private`,
    `headers`, `inet6`, and `unix_socket`. `base_url`, `decode_body`, `retry`, and `auth` are
    accepted but SDK-owned: the SDK always sets `base_url` to the client's, forces
    `decode_body: false` and `retry: false`, and drops `auth`. Any other key is an
    error, as are `receive_timeout`, `request_timeout` (also under `finch:`; use `:timeout`),
    `retry_delay`, `max_retries`, and `retry_log_level`. `finch:` must be a keyword list
    with the keys `name`, `pool_timeout`, `pool_tag`, `size`, `count`, `protocols`,
    `conn_opts`, `pool_max_idle_time`, `conn_max_idle_time`, `start_pool_metrics?`, and
    `http2`; `name:` cannot go with a pool key other than `pool_timeout` and `pool_tag`,
    and `finch:` cannot go with `connect_options:`. `connect_options:` must be a keyword
    list with the keys `timeout`, `protocols`, `transport_opts`, `proxy`,
    `proxy_headers`, `hostname`, and `client_settings`. Keys are checked, and values are
    not, apart from the shapes stated here: a wrong-typed value such as `finch: [size: :x]`
    or `adapter: 5` passes `new/1` and raises on the first call. `headers:` must be a map or a list of `{name, value}` pairs, a name being
    a binary or an atom and a value a binary or a list of binaries. The check runs on the
    options as Req resolves them: `config :req, :default_options` with `req_options`
    merged over it, the last of a repeated key winning, so an entry in that
    application config is validated too and an error names it as
    `config :req, :default_options`. Use `finch: [pool_timeout: ms]` for a pool timeout
    and `connect_options: [timeout: ms]` to bound connecting. A `finch: [name: pool]`
    that names a pool nobody started raises `ArgumentError` on the first call, a
    programming error like any other unstarted process.
  - `:retry` — a keyword list of `TypeSafe.RetryPolicy` fields (`:max_retries`,
    `:backoff_initial_ms`, `:backoff_max_ms`, `:backoff_jitter`, `:http_statuses`,
    `:respect_retry_after`, `:max_retry_after_ms`, `:api_connection_error`,
    `:api_timeout_error`) overriding the defaults, which retry 408, 429, 5xx, and
    connection errors up to twice with exponential backoff. Timeouts are not
    retried unless `api_timeout_error: true`. The resolved policy is stored in
    `client.retry`. An invalid value returns `{:error, %TypeSafe.Error{}}` naming
    `retry.<field>`; `retry: nil` gives `"retry must be a keyword list, got nil"`, an unknown
    key `"retry has unknown option(s): <keys>"`, and a repeated key
    `"retry.<key> given more than once"`.
  - `:timeout` — milliseconds each request attempt may wait for a response, default `10_000`.
    Must be a positive integer, at most `4_294_967_295`; `nil` and floats are rejected, and there is no environment
    fallback. Stored in `client.timeout`; a per-call `timeout:` overrides it.
  - `:get_env` — a `(String.t() -> String.t() | nil)` function, default `&System.get_env/1`.

  Every option value above is checked with a guard clause. A wrong-typed value
  or an invalid `:log_level` returns `{:error, %TypeSafe.Error{}}`, and so does a
  `:req_options` entry outside the allowlist — `new/1` never raises on bad input.

  Returns `{:ok, client}` or `{:error, %TypeSafe.Error{}}`.
  """
  @spec new(keyword()) :: {:ok, TypeSafe.Client.t()} | {:error, TypeSafe.Error.t()}
  defdelegate new(opts \\ []), to: TypeSafe.Config, as: :build

  @doc """
  Lists available models via `GET /v1/models`.

  Options:
  - `:headers` — a map merged onto this call's request; cannot override protected headers.
    A `nil` value deletes the header instead of sending it empty.
  - `:with_response` — when `true`, returns `t:with_response_result/0` instead of the bare
    list. Must be a boolean; a non-boolean value is rejected before any request is sent.
  - `:retry` — a keyword list merged field by field onto `client.retry` for this call only,
    e.g. `retry: [max_retries: 0]`. Invalid values (including `nil`) are rejected before any
    request is sent, with the messages listed under `new/1`'s `:retry` option.
  - `:timeout` — a positive integer in milliseconds that replaces `client.timeout` for this
    call, on every attempt. It bounds each socket read, not connecting: connecting uses Finch's
    5_000 ms default, set with `req_options: [connect_options: [timeout: ms]]` on `new/1`.
    `TypeSafe.Error.Timeout.timeout_ms` is this configured per-read value, not the elapsed
    time, so a connect timeout reports it too. Invalid values (including `nil`) are rejected
    before any request is sent.

  `opts` that is not a keyword list returns
  `{:error, %TypeSafe.Error{message: "list_models/2 requires a keyword list of options"}}`,
  and a key given twice returns `"<key> given more than once"`.

  A response whose body is not `%{"models" => [...]}` returns `{:error, %TypeSafe.Error{}}`
  instead of raising.

  Retryable failures are retried per the client's retry policy; once retries run out, the last
  error is returned. Timeouts are not retried unless `retry: [api_timeout_error: true]`.

  A non-2xx HTTP response returns the status-mapped error struct:
  `TypeSafe.Error.BadRequest` (400), `TypeSafe.Error.Authentication` (401),
  `TypeSafe.Error.PermissionDenied` (403), `TypeSafe.Error.NotFound` (404),
  `TypeSafe.Error.UnprocessableEntity` (422), `TypeSafe.Error.RateLimit` (429,
  with `retry_after_ms`), `TypeSafe.Error.InternalServer` (5xx, including
  529), or `TypeSafe.Error.API` for any other non-2xx status (e.g. 409, 418).
  A transport failure returns `TypeSafe.Error.Timeout` (the effective
  timeout was exceeded) or `TypeSafe.Error.Connection` (any other transport
  failure — closed socket, DNS, TLS, etc.). When more calls run at once than the
  connection pool holds and none frees up within the pool timeout, the result is
  `TypeSafe.Error.Connection` with `reason: :pool_timeout`, which is not retried.
  Size the pool with `req_options: [finch: [size: n]]` or wait longer with
  `req_options: [finch: [pool_timeout: ms]]`, as the README describes.

  Returns `{:ok, [map()]}` (or `{:ok, with_response_result}`) or `{:error, Exception.t()}`.
  """
  @spec list_models(TypeSafe.Client.t(), keyword()) ::
          {:ok, [map()] | with_response_result()} | {:error, Exception.t()}
  defdelegate list_models(client, opts \\ []), to: TypeSafe.HTTP

  @doc """
  Asks typed questions about `state` via `POST /v1/systemone`.

  `request` is `%{state: term(), questions: %{id => question}, ...extra}` — an
  atom-keyed map with a `:state` key. A request missing `:state`, or a
  string-keyed request map, returns `{:error, %TypeSafe.Error{}}` with zero
  HTTP calls rather than raising. The request's own `:model` wins when present
  and non-`nil`; `nil` and absent are treated the same and fall back to
  `client.default_model`. Any other top-level keys (including `nil` values)
  are forwarded as-is.

  Every question is validated before any request is sent: an empty
  `questions` map, a `score` question whose criteria is not a list (or has no
  `criteria` key at all, atom- or string-keyed), or a `score` question with
  fewer than two criteria all return `{:error, %TypeSafe.Error{}}` with zero
  HTTP calls.

  Options:
  - `:headers` — a map merged onto this call's request; cannot override protected headers.
    A `nil` value deletes the header instead of sending it empty.
  - `:with_response` — when `true`, returns `t:with_response_result/0` instead of the bare
    body. Must be a boolean; a non-boolean value is rejected before any request is sent.
  - `:retry` — a keyword list merged field by field onto `client.retry` for this call only,
    e.g. `retry: [max_retries: 0]`. Invalid values (including `nil`) are rejected before any
    request is sent, with the messages listed under `new/1`'s `:retry` option.
  - `:timeout` — a positive integer in milliseconds that replaces `client.timeout` for this
    call, on every attempt. It bounds each socket read, not connecting: connecting uses Finch's
    5_000 ms default, set with `req_options: [connect_options: [timeout: ms]]` on `new/1`.
    `TypeSafe.Error.Timeout.timeout_ms` is this configured per-read value, not the elapsed
    time, so a connect timeout reports it too. Invalid values (including `nil`) are rejected
    before any request is sent.

  `opts` that is not a keyword list returns
  `{:error, %TypeSafe.Error{message: "system_one/3 requires a keyword list of options"}}`,
  and a key given twice returns `"<key> given more than once"`.

  Request content of these shapes (a PID, a tuple, a struct without a
  `Jason.Encoder`, a tuple map key, or invalid UTF-8 in `state`, a question, or an
  extra key) returns
  `{:error, %TypeSafe.Error{message: "system_one/3 request cannot be encoded as JSON"}}`
  and sends nothing. The message never includes the content. Malformed Elixir data
  such as an improper list still raises: decoded JSON cannot produce it.

  Retryable failures are retried per the client's retry policy, and each retry sends the same
  request body. A timeout is not retried by default: a timed-out request may already have been
  processed and billed, and the API has no idempotency key. Opt in with
  `retry: [api_timeout_error: true]`. Retries add an `X-TypeSafe-Retry-Count` header.

  A non-2xx HTTP response returns the status-mapped error struct:
  `TypeSafe.Error.BadRequest` (400), `TypeSafe.Error.Authentication` (401),
  `TypeSafe.Error.PermissionDenied` (403), `TypeSafe.Error.NotFound` (404),
  `TypeSafe.Error.UnprocessableEntity` (422), `TypeSafe.Error.RateLimit` (429,
  with `retry_after_ms`), `TypeSafe.Error.InternalServer` (5xx, including
  529), or `TypeSafe.Error.API` for any other non-2xx status (e.g. 409, 418).
  A transport failure returns `TypeSafe.Error.Timeout` (the effective
  timeout was exceeded) or `TypeSafe.Error.Connection` (any other transport
  failure — closed socket, DNS, TLS, etc.). When more calls run at once than the
  connection pool holds and none frees up within the pool timeout, the result is
  `TypeSafe.Error.Connection` with `reason: :pool_timeout`, which is not retried.
  Size the pool with `req_options: [finch: [size: n]]` or wait longer with
  `req_options: [finch: [pool_timeout: ms]]`, as the README describes.

  Returns `{:ok, decoded_body}` (or `{:ok, with_response_result}`) or `{:error, Exception.t()}`.
  """
  @spec system_one(TypeSafe.Client.t(), request(), keyword()) ::
          {:ok, term() | with_response_result()} | {:error, Exception.t()}
  defdelegate system_one(client, request, opts \\ []), to: TypeSafe.HTTP

  @doc """
  Builds a `noul` question with no instructions and no criteria.

  ## Examples

      iex> TypeSafe.noul()
      %{type: "noul", instructions: nil}

  """
  @spec noul() :: question()
  defdelegate noul(), to: TypeSafe.Questions

  @doc "Builds a `noul` question with `instructions` and no criteria key."
  @spec noul(term()) :: question()
  defdelegate noul(instructions), to: TypeSafe.Questions

  @doc """
  Builds a `noul` question with `instructions` and `criteria`. `criteria`
  must be `nil` or a map, ideally with a `true` key, a `false` key, or both;
  the keys are not checked. Any other `criteria` (a string, list, or number)
  raises `FunctionClauseError`, like `choice/2` and `score/2`.
  """
  @spec noul(term(), map() | nil) :: question()
  defdelegate noul(instructions, criteria), to: TypeSafe.Questions

  @doc """
  Builds a `choice` question. `criteria` must be a map (a list raises
  `FunctionClauseError`, matching the JS SDK's runtime throw).
  """
  @spec choice(term(), map()) :: question()
  defdelegate choice(instructions, criteria), to: TypeSafe.Questions

  @doc """
  Builds a `score` question. `criteria` must be a list, indexed by score from
  zero (a map raises `FunctionClauseError`, matching the JS SDK's runtime
  throw).
  """
  @spec score(term(), list()) :: question()
  defdelegate score(instructions, criteria), to: TypeSafe.Questions
end
