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
      "0.1.0"

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
  A blank (empty or whitespace-only) option or environment value counts as
  unset for `:api_key`.

  Options:
  - `:api_key` — required unless `TYPESAFE_API_KEY` is set. Must be a string.
  - `:base_url` — default `https://api.typesafe.ai`. Must be a string; trailing slashes
    are stripped.
  - `:default_model` — default `jev-latest`. Must be a string.
  - `:log_level` — one of `t:log_level/0`, default `:warning`.
  - `:default_headers` — a map merged onto every request, default `%{}`.
  - `:req_options` — a keyword list merged into `Req.new/1` (e.g. `adapter:` for tests).
    `decode_body` and `retry` are SDK-owned and are always forced to `false`
    regardless of what `req_options` requests.
  - `:get_env` — a `(String.t() -> String.t() | nil)` function, default `&System.get_env/1`.

  Every option value above is checked with a guard clause. A wrong-typed value
  or an invalid `:log_level` returns `{:error, %TypeSafe.Error{}}` — `new/1`
  never raises on bad input.

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

  A response whose body is not `%{"models" => [...]}` returns `{:error, %TypeSafe.Error{}}`
  instead of raising.

  A non-2xx HTTP response returns the status-mapped error struct:
  `TypeSafe.Error.BadRequest` (400), `TypeSafe.Error.Authentication` (401),
  `TypeSafe.Error.PermissionDenied` (403), `TypeSafe.Error.NotFound` (404),
  `TypeSafe.Error.UnprocessableEntity` (422), `TypeSafe.Error.RateLimit` (429,
  with `retry_after_ms`), `TypeSafe.Error.InternalServer` (5xx, including
  529), or `TypeSafe.Error.API` for any other non-2xx status (e.g. 409, 418).
  A transport failure returns `TypeSafe.Error.Timeout` (the configured
  timeout was exceeded) or `TypeSafe.Error.Connection` (any other transport
  failure — closed socket, DNS, TLS, etc.).

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

  A non-2xx HTTP response returns the status-mapped error struct:
  `TypeSafe.Error.BadRequest` (400), `TypeSafe.Error.Authentication` (401),
  `TypeSafe.Error.PermissionDenied` (403), `TypeSafe.Error.NotFound` (404),
  `TypeSafe.Error.UnprocessableEntity` (422), `TypeSafe.Error.RateLimit` (429,
  with `retry_after_ms`), `TypeSafe.Error.InternalServer` (5xx, including
  529), or `TypeSafe.Error.API` for any other non-2xx status (e.g. 409, 418).
  A transport failure returns `TypeSafe.Error.Timeout` (the configured
  timeout was exceeded) or `TypeSafe.Error.Connection` (any other transport
  failure — closed socket, DNS, TLS, etc.).

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
  may be `nil`, or a map with a `true` key, a `false` key, or both.
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
