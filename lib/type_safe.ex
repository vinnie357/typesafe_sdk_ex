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

  ## Examples

      iex> TypeSafe.version()
      "0.1.0"

  """
  @spec version() :: String.t()
  def version do
    Application.spec(:typesafe_sdk, :vsn) |> to_string()
  end

  @doc """
  Builds a `TypeSafe.Client` (spec §4).

  Resolves `:api_key`, `:base_url`, `:default_model`, and `:log_level` in this
  order: the option, then the matching `TYPESAFE_*` environment variable (read
  through `:get_env`, which defaults to `&System.get_env/1`), then a default.
  A blank (empty or whitespace-only) environment value counts as unset.

  Options:
  - `:api_key` — required unless `TYPESAFE_API_KEY` is set.
  - `:base_url` — default `#{@default_base_url}`. Trailing slashes are stripped.
  - `:default_model` — default `#{@default_model}`.
  - `:log_level` — one of `t:log_level/0`, default `:warning`.
  - `:default_headers` — a map merged onto every request, default `%{}`.
  - `:req_options` — a keyword list merged into `Req.new/1` (e.g. `adapter:` for tests).
  - `:get_env` — a `(String.t() -> String.t() | nil)` function, default `&System.get_env/1`.

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
      {:ok, opts} -> build_client_from_opts(opts)
      {:error, invalid_keys} -> {:error, invalid_options_error(invalid_keys)}
    end
  end

  @doc """
  Lists available models via `GET /v1/models` (spec §3).

  Options:
  - `:headers` — a map merged onto this call's request; cannot override protected headers.
  - `:with_response` — when `true`, returns `t:with_response_result/0` instead of the bare list.

  Returns `{:ok, [map()]}` (or `{:ok, with_response_result}`) or `{:error, Exception.t()}`.
  """
  @spec list_models(TypeSafe.Client.t(), keyword()) ::
          {:ok, [map()] | with_response_result()} | {:error, Exception.t()}
  def list_models(%TypeSafe.Client{} = client, opts \\ []) do
    case Keyword.validate(opts, [:headers, :with_response]) do
      {:ok, opts} -> perform_list_models(client, opts)
      {:error, invalid_keys} -> {:error, invalid_options_error(invalid_keys)}
    end
  end

  @doc """
  Asks typed questions about `state` via `POST /v1/systemone` (spec §3, §8).

  `request` is `%{state: term(), questions: %{id => question}, ...extra}`. The
  request's own `:model` wins when present, otherwise `client.default_model` is
  used. Any other top-level keys (including `nil` values) are forwarded as-is.

  Every question is validated before any request is sent (spec §8): an empty
  `questions` map, a `score` question whose criteria is not a list, or a
  `score` question with fewer than two criteria all return `{:error, %TypeSafe.Error{}}`
  with zero HTTP calls.

  Options:
  - `:headers` — a map merged onto this call's request; cannot override protected headers.
  - `:with_response` — when `true`, returns `t:with_response_result/0` instead of the bare body.

  Returns `{:ok, decoded_body}` (or `{:ok, with_response_result}`) or `{:error, Exception.t()}`.
  """
  @spec system_one(TypeSafe.Client.t(), request(), keyword()) ::
          {:ok, term() | with_response_result()} | {:error, Exception.t()}
  def system_one(
        %TypeSafe.Client{} = client,
        %{state: state, questions: questions} = request,
        opts \\ []
      )
      when is_map(questions) do
    with {:ok, opts} <- Keyword.validate(opts, [:headers, :with_response]),
         {:ok, built_questions} <- build_questions(questions) do
      payload = build_payload(client, request, state, built_questions)
      headers = Keyword.get(opts, :headers, %{})
      with_response? = Keyword.get(opts, :with_response, false)
      req = build_request(client, headers)

      case Req.request(req, method: :post, url: "/v1/systemone", json: payload) do
        {:ok, response} -> handle_response(response, with_response?)
        {:error, exception} -> {:error, wrap_transport_error(exception)}
      end
    else
      {:error, %TypeSafe.Error{}} = error -> error
      {:error, invalid_keys} -> {:error, invalid_options_error(invalid_keys)}
    end
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

    req =
      [base_url: base_url, decode_body: false]
      |> Keyword.merge(req_options)
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
    case Keyword.get(opts, :api_key) do
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

  defp perform_list_models(client, opts) do
    headers = Keyword.get(opts, :headers, %{})
    with_response? = Keyword.get(opts, :with_response, false)
    req = build_request(client, headers)

    case Req.request(req, method: :get, url: "/v1/models") do
      {:ok, response} -> handle_list_models_response(response, with_response?)
      {:error, exception} -> {:error, wrap_transport_error(exception)}
    end
  end

  defp handle_list_models_response(%Req.Response{status: status} = response, with_response?)
       when status in 200..299 do
    %{"models" => models} = decode_body(response)
    {:ok, finalize(models, response, with_response?)}
  end

  defp handle_list_models_response(%Req.Response{status: status}, _with_response?) do
    {:error, %TypeSafe.Error{message: "#{status} error"}}
  end

  defp build_payload(client, request, state, built_questions) do
    extra = Map.drop(request, [:state, :questions])

    %{model: client.default_model}
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

  defp validate_question(id, %{type: "score", criteria: criteria}) when not is_list(criteria) do
    {:error,
     %TypeSafe.Error{
       message:
         ~s(Score question "#{id}" has criteria that are not a list; ) <>
           "score criteria must be a list of descriptions indexed by score from zero."
     }}
  end

  defp validate_question(id, %{type: "score", criteria: criteria}) when length(criteria) < 2 do
    {:error,
     %TypeSafe.Error{
       message:
         ~s(Score question "#{id}" has #{length(criteria)} criteria; ) <>
           "at least two scores are required."
     }}
  end

  defp validate_question(_id, _question), do: :ok

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
    end
  end

  defp merge_headers(req, headers) do
    Enum.reduce(headers, req, fn {key, value}, acc ->
      Req.Request.put_header(acc, to_string(key), to_string(value))
    end)
  end

  defp apply_protected_headers(req, auth) do
    req
    |> Req.Request.delete_header("x-typesafe-retry-count")
    |> Req.Request.delete_header("content-type")
    |> Req.Request.put_header("authorization", auth)
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
