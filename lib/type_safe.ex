defmodule TypeSafe do
  @moduledoc """
  Elixir port of the TypeSafe AI SDK, built on Req.

  Configure a client with `new/1` (reading `TYPESAFE_API_KEY` and friends from
  the environment by default), then call `system_one/3` to ask typed questions
  about application state, or `list_models/2` to list available models.

  Build questions with `noul/0`, `noul/1`, `noul/2`, `choice/2`, and `score/2`.
  """

  @typedoc "Log level accepted by `new/1`'s `:log_level` option (spec §7)."
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

  @default_base_url "https://api.typesafe.ai"
  @default_model "jev-latest"
  @default_log_level :warning
  @default_timeout 10_000
  @valid_log_levels [:debug, :info, :warning, :error, :off]
  @version Mix.Project.config()[:version]

  @log_levels %{
    "debug" => :debug,
    "info" => :info,
    "warn" => :warning,
    "warning" => :warning,
    "error" => :error,
    "off" => :off
  }

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
    case Application.spec(:typesafe_sdk, :vsn) do
      nil -> @version
      vsn -> to_string(vsn)
    end
  end

  @doc """
  Builds a `TypeSafe.Client` (spec §4).

  Resolves `:api_key`, `:base_url`, `:default_model`, and `:log_level` in this
  order: the option, then the matching `TYPESAFE_*` environment variable (read
  through `:get_env`, which defaults to `&System.get_env/1`), then a default.
  A blank (empty or whitespace-only) option or environment value counts as
  unset for `:api_key` (spec §12 q16).

  Options:
  - `:api_key` — required unless `TYPESAFE_API_KEY` is set. Must be a string.
  - `:base_url` — default `#{@default_base_url}`. Must be a string; trailing slashes are stripped.
  - `:default_model` — default `#{@default_model}`. Must be a string.
  - `:log_level` — one of `t:log_level/0`, default `:warning`.
  - `:default_headers` — a map merged onto every request, default `%{}`.
  - `:req_options` — a keyword list merged into `Req.new/1` (e.g. `adapter:` for tests).
    `decode_body` and `retry` are SDK-owned (spec §3, §5) and are always forced to
    `false` regardless of what `req_options` requests.
  - `:get_env` — a `(String.t() -> String.t() | nil)` function, default `&System.get_env/1`.

  Every option value above is checked with a guard clause. A wrong-typed value
  or an invalid `:log_level` returns `{:error, %TypeSafe.Error{}}` — `new/1`
  never raises on bad input.

  Returns `{:ok, client}` or `{:error, %TypeSafe.Error{}}`.
  """
  @spec new(keyword()) :: {:ok, TypeSafe.Client.t()} | {:error, TypeSafe.Error.t()}
  def new(opts \\ []) do
    valid_keys = [
      :api_key,
      :base_url,
      :default_model,
      :log_level,
      :default_headers,
      :req_options,
      :get_env
    ]

    case Keyword.validate(opts, valid_keys) do
      {:ok, opts} -> validate_and_build(opts)
      {:error, invalid_keys} -> {:error, invalid_options_error(invalid_keys)}
    end
  end

  @doc """
  Lists available models via `GET /v1/models` (spec §3).

  Options:
  - `:headers` — a map merged onto this call's request; cannot override protected headers.
    A `nil` value deletes the header instead of sending it empty.
  - `:with_response` — when `true`, returns `t:with_response_result/0` instead of the bare
    list. Must be a boolean; a non-boolean value is rejected before any request is sent.

  A response whose body is not `%{"models" => [...]}` returns `{:error, %TypeSafe.Error{}}`
  instead of raising.

  Returns `{:ok, [map()]}` (or `{:ok, with_response_result}`) or `{:error, Exception.t()}`.
  """
  @spec list_models(TypeSafe.Client.t(), keyword()) ::
          {:ok, [map()] | with_response_result()} | {:error, Exception.t()}
  def list_models(%TypeSafe.Client{} = client, opts \\ []) do
    case Keyword.validate(opts, [:headers, :with_response]) do
      {:ok, opts} -> validate_and_list_models(client, opts)
      {:error, invalid_keys} -> {:error, invalid_options_error(invalid_keys)}
    end
  end

  @doc """
  Asks typed questions about `state` via `POST /v1/systemone` (spec §3, §8).

  `request` is `%{state: term(), questions: %{id => question}, ...extra}` — an
  atom-keyed map with a `:state` key (spec §8 "Request shape contract"). A
  request missing `:state`, or a string-keyed request map, returns
  `{:error, %TypeSafe.Error{}}` with zero HTTP calls rather than raising. The
  request's own `:model` wins when present and non-`nil`; `nil` and absent are
  treated the same and fall back to `client.default_model`. Any other
  top-level keys (including `nil` values) are forwarded as-is.

  Every question is validated before any request is sent (spec §8): an empty
  `questions` map, a `score` question whose criteria is not a list (or has no
  `criteria` key at all, atom- or string-keyed), or a `score` question with
  fewer than two criteria all return `{:error, %TypeSafe.Error{}}` with zero
  HTTP calls.

  Options:
  - `:headers` — a map merged onto this call's request; cannot override protected headers.
    A `nil` value deletes the header instead of sending it empty.
  - `:with_response` — when `true`, returns `t:with_response_result/0` instead of the bare
    body. Must be a boolean; a non-boolean value is rejected before any request is sent.

  Returns `{:ok, decoded_body}` (or `{:ok, with_response_result}`) or `{:error, Exception.t()}`.
  """
  @spec system_one(TypeSafe.Client.t(), request(), keyword()) ::
          {:ok, term() | with_response_result()} | {:error, Exception.t()}
  def system_one(client, request, opts \\ [])

  def system_one(
        %TypeSafe.Client{} = client,
        %{state: state, questions: questions} = request,
        opts
      )
      when is_map(questions) do
    with {:ok, opts} <- Keyword.validate(opts, [:headers, :with_response]),
         :ok <- validate_call_opts(opts),
         {:ok, built_questions} <- build_questions(questions) do
      payload = build_payload(client, request, state, built_questions)
      headers = Keyword.get(opts, :headers, %{})
      with_response? = Keyword.get(opts, :with_response, false)
      req = build_request(client, headers)

      case Req.request(req,
             method: :post,
             url: "/v1/systemone",
             json: payload,
             receive_timeout: client.timeout
           ) do
        {:ok, response} -> handle_response(response, with_response?)
        {:error, exception} -> {:error, wrap_transport_error(exception)}
      end
    else
      {:error, %TypeSafe.Error{}} = error -> error
      {:error, invalid_keys} -> {:error, invalid_options_error(invalid_keys)}
    end
  end

  def system_one(%TypeSafe.Client{}, request, _opts) when is_map(request) do
    {:error,
     %TypeSafe.Error{
       message: "system_one/3 request must be an atom-keyed map with a :state key (spec §8)."
     }}
  end

  @doc """
  Builds a `noul` question with no instructions and no criteria (spec §8).

  ## Examples

      iex> TypeSafe.noul()
      %{type: "noul", instructions: nil}

  """
  @spec noul() :: question()
  def noul, do: %{type: "noul", instructions: nil}

  @doc "Builds a `noul` question with `instructions` and no criteria key (spec §8)."
  @spec noul(term()) :: question()
  def noul(instructions), do: %{type: "noul", instructions: instructions}

  @doc """
  Builds a `noul` question with `instructions` and `criteria` (spec §8). `criteria`
  may be `nil`, or a map with a `true` key, a `false` key, or both.
  """
  @spec noul(term(), map() | nil) :: question()
  def noul(instructions, criteria) do
    %{type: "noul", instructions: instructions, criteria: criteria}
  end

  @doc """
  Builds a `choice` question. `criteria` must be a map (a list raises
  `FunctionClauseError`, matching the JS SDK's runtime throw, spec §8).
  """
  @spec choice(term(), map()) :: question()
  def choice(instructions, criteria) when is_map(criteria) do
    %{type: "choice", instructions: instructions, criteria: criteria}
  end

  @doc """
  Builds a `score` question. `criteria` must be a list, indexed by score from
  zero (a map raises `FunctionClauseError`, matching the JS SDK's runtime
  throw, spec §8).
  """
  @spec score(term(), list()) :: question()
  def score(instructions, criteria) when is_list(criteria) do
    %{type: "score", instructions: instructions, criteria: criteria}
  end

  defp validate_and_build(opts) do
    case validate_option_values(opts) do
      :ok -> build_client_from_opts(opts)
      {:error, %TypeSafe.Error{}} = error -> error
    end
  end

  defp validate_option_values(opts) do
    with :ok <- validate_type(opts, :api_key, &is_binary/1, "api_key must be a string"),
         :ok <- validate_type(opts, :base_url, &is_binary/1, "base_url must be a string"),
         :ok <-
           validate_type(opts, :default_model, &is_binary/1, "default_model must be a string"),
         :ok <- validate_type(opts, :default_headers, &is_map/1, "default_headers must be a map"),
         :ok <-
           validate_type(
             opts,
             :req_options,
             &Keyword.keyword?/1,
             "req_options must be a keyword list"
           ),
         :ok <-
           validate_type(
             opts,
             :get_env,
             &is_function(&1, 1),
             "get_env must be a 1-arity function"
           ) do
      validate_log_level_value(opts)
    end
  end

  defp validate_type(opts, key, predicate, message) do
    case Keyword.fetch(opts, key) do
      :error -> :ok
      {:ok, value} -> validate_predicate(predicate.(value), message)
    end
  end

  defp validate_log_level_value(opts) do
    case Keyword.fetch(opts, :log_level) do
      :error ->
        :ok

      {:ok, value} ->
        validate_predicate(
          value in @valid_log_levels,
          "log_level must be one of #{inspect(@valid_log_levels)}"
        )
    end
  end

  defp validate_predicate(true, _message), do: :ok
  defp validate_predicate(false, message), do: {:error, %TypeSafe.Error{message: message}}

  defp validate_call_opts(opts) do
    case Keyword.fetch(opts, :with_response) do
      :error -> :ok
      {:ok, value} -> validate_predicate(is_boolean(value), "with_response must be a boolean")
    end
  end

  defp build_client_from_opts(opts) do
    get_env = Keyword.get(opts, :get_env, &System.get_env/1)

    case resolve_api_key(opts, get_env) do
      {:ok, api_key} -> build_client(opts, api_key, get_env)
      {:error, %TypeSafe.Error{}} = error -> error
    end
  end

  defp build_client(opts, api_key, get_env) do
    base_url =
      opts
      |> resolve_string(:base_url, "TYPESAFE_BASE_URL", get_env, @default_base_url)
      |> String.trim_trailing("/")

    default_model =
      resolve_string(opts, :default_model, "TYPESAFE_DEFAULT_MODEL", get_env, @default_model)

    log_level = resolve_log_level(opts, get_env)
    default_headers = Keyword.get(opts, :default_headers, %{})
    req_options = Keyword.get(opts, :req_options, [])

    req_config =
      [base_url: base_url]
      |> Keyword.merge(req_options)
      |> Keyword.put(:decode_body, false)
      |> Keyword.put(:retry, false)

    req =
      req_config
      |> Req.new()
      |> Req.Request.put_header("authorization", "Bearer " <> api_key)

    {:ok,
     %TypeSafe.Client{
       base_url: base_url,
       default_model: default_model,
       log_level: log_level,
       retry: %TypeSafe.RetryPolicy{},
       timeout: @default_timeout,
       default_headers: default_headers,
       req: req
     }}
  end

  defp resolve_api_key(opts, get_env) do
    case opts |> Keyword.get(:api_key) |> blank_to_nil() do
      nil ->
        case get_env.("TYPESAFE_API_KEY") |> blank_to_nil() do
          nil -> {:error, %TypeSafe.Error{message: "TYPESAFE_API_KEY is required."}}
          value -> {:ok, value}
        end

      value ->
        {:ok, value}
    end
  end

  defp resolve_string(opts, key, env_name, get_env, default) do
    case Keyword.get(opts, key) do
      nil ->
        case get_env.(env_name) |> blank_to_nil() do
          nil -> default
          value -> value
        end

      value ->
        value
    end
  end

  defp resolve_log_level(opts, get_env) do
    case Keyword.get(opts, :log_level) do
      nil ->
        case get_env.("TYPESAFE_LOG_LEVEL") |> blank_to_nil() do
          nil -> @default_log_level
          value -> Map.get(@log_levels, String.downcase(value), @default_log_level)
        end

      value when is_atom(value) ->
        value
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_and_list_models(client, opts) do
    case validate_call_opts(opts) do
      :ok -> perform_list_models(client, opts)
      {:error, %TypeSafe.Error{}} = error -> error
    end
  end

  defp perform_list_models(client, opts) do
    headers = Keyword.get(opts, :headers, %{})
    with_response? = Keyword.get(opts, :with_response, false)
    req = build_request(client, headers)

    case Req.request(req, method: :get, url: "/v1/models", receive_timeout: client.timeout) do
      {:ok, response} -> handle_list_models_response(response, with_response?)
      {:error, exception} -> {:error, wrap_transport_error(exception)}
    end
  end

  defp handle_list_models_response(%Req.Response{status: status} = response, with_response?)
       when status in 200..299 do
    case decode_body(response) do
      %{"models" => models} when is_list(models) ->
        {:ok, finalize(models, response, with_response?)}

      _unexpected_shape ->
        {:error, unexpected_models_shape_error()}
    end
  end

  defp handle_list_models_response(%Req.Response{status: status}, _with_response?) do
    {:error, %TypeSafe.Error{message: "#{status} error"}}
  end

  defp unexpected_models_shape_error do
    %TypeSafe.Error{
      message:
        "Unexpected response shape from GET /v1/models; expected a map with a \"models\" list."
    }
  end

  defp build_payload(client, request, state, built_questions) do
    model =
      case Map.get(request, :model) do
        nil -> client.default_model
        value -> value
      end

    extra = Map.drop(request, [:state, :questions, :model])

    %{model: model}
    |> Map.merge(extra)
    |> Map.merge(%{state: state, questions: built_questions})
  end

  defp build_questions(questions) when map_size(questions) == 0 do
    {:error, %TypeSafe.Error{message: "At least one question is required."}}
  end

  defp build_questions(questions) do
    Enum.reduce_while(questions, {:ok, %{}}, fn {id, question}, {:ok, acc} ->
      case validate_question(id, question) do
        :ok -> {:cont, {:ok, Map.put(acc, id, question)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_question(id, question) do
    case question_type(question) do
      "score" -> validate_score(id, question)
      _other_type -> :ok
    end
  end

  defp question_type(%{type: type}), do: type
  defp question_type(%{"type" => type}), do: type
  defp question_type(_question), do: nil

  defp validate_score(id, question) do
    case fetch_criteria(question) do
      {:ok, criteria} when is_list(criteria) -> validate_score_length(id, criteria)
      _missing_or_not_list -> {:error, score_not_list_error(id)}
    end
  end

  defp fetch_criteria(%{criteria: criteria}), do: {:ok, criteria}
  defp fetch_criteria(%{"criteria" => criteria}), do: {:ok, criteria}
  defp fetch_criteria(_question), do: :error

  defp validate_score_length(id, criteria) when length(criteria) < 2 do
    {:error, score_count_error(id, criteria)}
  end

  defp validate_score_length(_id, _criteria), do: :ok

  defp score_not_list_error(id) do
    %TypeSafe.Error{
      message:
        ~s(Score question "#{id}" has criteria that are not a list; ) <>
          "score criteria must be a list of descriptions indexed by score from zero."
    }
  end

  defp score_count_error(id, criteria) do
    %TypeSafe.Error{
      message:
        ~s(Score question "#{id}" has #{length(criteria)} criteria; ) <>
          "at least two scores are required."
    }
  end

  defp handle_response(%Req.Response{status: status} = response, with_response?)
       when status in 200..299 do
    {:ok, finalize(decode_body(response), response, with_response?)}
  end

  defp handle_response(%Req.Response{status: status}, _with_response?) do
    {:error, %TypeSafe.Error{message: "#{status} error"}}
  end

  defp decode_body(%Req.Response{body: body}) when body in [nil, ""], do: nil

  defp decode_body(%Req.Response{body: body}) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp finalize(data, _response, false), do: data

  defp finalize(data, response, true) do
    %{data: data, response: response, request_id: request_id(response)}
  end

  defp request_id(response) do
    case Req.Response.get_header(response, "x-typesafe-request-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  defp wrap_transport_error(exception) do
    %TypeSafe.Error{message: Exception.message(exception)}
  end

  defp invalid_options_error(invalid_keys) do
    %TypeSafe.Error{message: "Unknown option(s): #{Enum.join(invalid_keys, ", ")}"}
  end

  defp build_request(client, call_headers) do
    auth = auth_header(client)

    client.req
    |> merge_headers(client.default_headers)
    |> merge_headers(call_headers)
    |> apply_protected_headers(auth)
  end

  defp auth_header(client) do
    case Req.Request.get_header(client.req, "authorization") do
      [value | _] -> value
      [] -> nil
    end
  end

  defp merge_headers(req, headers) do
    Enum.reduce(headers, req, fn {key, value}, acc ->
      put_or_delete_header(acc, to_string(key), value)
    end)
  end

  defp put_or_delete_header(req, name, nil), do: Req.Request.delete_header(req, name)

  defp put_or_delete_header(req, name, value),
    do: Req.Request.put_header(req, name, to_string(value))

  defp apply_protected_headers(req, auth) do
    req
    |> Req.Request.delete_header("x-typesafe-retry-count")
    |> Req.Request.delete_header("content-type")
    |> put_or_delete_header("authorization", auth)
    |> Req.Request.put_header("accept", "application/json")
    |> Req.Request.put_header("user-agent", sdk_user_agent())
    |> Req.Request.put_header("x-typesafe-sdk", sdk_user_agent())
    |> Req.Request.put_header("x-typesafe-runtime", runtime_string())
  end

  defp sdk_user_agent, do: "typesafe-sdk-ex/" <> version()

  defp runtime_string do
    "elixir/#{System.version()} (otp/#{:erlang.system_info(:otp_release)})"
  end
end
