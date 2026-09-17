defmodule TypeSafe.Config do
  # Client option and environment-variable resolution and validation.
  # `TypeSafe.new/1` delegates here; see its `@doc` for the full option
  # reference. Internal implementation detail behind the `TypeSafe` facade.
  @moduledoc false

  @valid_keys [
    :api_key,
    :base_url,
    :default_model,
    :log_level,
    :default_headers,
    :req_options,
    :get_env
  ]

  @default_base_url "https://api.typesafe.ai"
  @default_model "jev-latest"
  @default_log_level :warning
  @default_timeout 10_000
  @valid_log_levels [:debug, :info, :warning, :error, :off]

  @log_levels %{
    "debug" => :debug,
    "info" => :info,
    "warn" => :warning,
    "warning" => :warning,
    "error" => :error,
    "off" => :off
  }

  @doc "Builds a `TypeSafe.Client` from `opts` — see `TypeSafe.new/1` for the full contract."
  @spec build(keyword()) :: {:ok, TypeSafe.Client.t()} | {:error, TypeSafe.Error.t()}
  def build(opts) do
    case Keyword.validate(opts, @valid_keys) do
      {:ok, opts} -> validate_and_build(opts)
      {:error, invalid_keys} -> {:error, invalid_options_error(invalid_keys)}
    end
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

    req = TypeSafe.HTTP.new_client_req(base_url, req_options, api_key)

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

  defp invalid_options_error(invalid_keys) do
    %TypeSafe.Error{message: "Unknown option(s): #{Enum.join(invalid_keys, ", ")}"}
  end
end
