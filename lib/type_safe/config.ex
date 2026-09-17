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
  @spec build(term()) :: {:ok, TypeSafe.Client.t()} | {:error, TypeSafe.Error.t()}
  def build(opts) do
    case validate_predicate(Keyword.keyword?(opts), "new/1 requires a keyword list of options") do
      :ok -> validate_keys_and_build(opts)
      {:error, %TypeSafe.Error{}} = error -> error
    end
  end

  defp validate_keys_and_build(opts) do
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
    with :ok <- validate_nilable_type(opts, :api_key, &is_binary/1, "api_key must be a string"),
         :ok <- validate_nilable_type(opts, :base_url, &is_binary/1, "base_url must be a string"),
         :ok <-
           validate_nilable_type(
             opts,
             :default_model,
             &is_binary/1,
             "default_model must be a string"
           ),
         :ok <-
           validate_type(
             opts,
             :default_headers,
             &valid_headers?/1,
             "default_headers must be a map with binary/atom/number/nil values (lists are not allowed)"
           ),
         :ok <-
           validate_type(
             opts,
             :req_options,
             &Keyword.keyword?/1,
             "req_options must be a keyword list"
           ),
         :ok <- validate_req_options_scope(opts),
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

  # Like `validate_type/4`, but an explicit `nil` means "not given" (spec §4
  # R1) for the four options that fall back to an env var and then a
  # default. `default_headers`, `req_options`, and `get_env` stay strict —
  # they have no env fallback, so `nil` there is still a type error.
  defp validate_nilable_type(opts, key, predicate, message) do
    case Keyword.fetch(opts, key) do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, value} -> validate_predicate(predicate.(value), message)
    end
  end

  defp validate_req_options_scope(opts) do
    req_options = Keyword.get(opts, :req_options, [])

    rejects_receive_timeout =
      Keyword.keyword?(req_options) and Keyword.has_key?(req_options, :receive_timeout)

    validate_predicate(
      not rejects_receive_timeout,
      "req_options must not set receive_timeout; use the client's own timeout option instead"
    )
  end

  defp validate_log_level_value(opts) do
    case Keyword.fetch(opts, :log_level) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, value} ->
        validate_predicate(
          value in @valid_log_levels,
          "log_level must be one of #{inspect(@valid_log_levels)}"
        )
    end
  end

  defp valid_headers?(headers) when is_map(headers) do
    Enum.all?(headers, fn {_name, value} -> valid_header_value?(value) end)
  end

  defp valid_headers?(_headers), do: false

  defp valid_header_value?(nil), do: true
  defp valid_header_value?(value) when is_binary(value), do: true
  defp valid_header_value?(value) when is_atom(value), do: true
  defp valid_header_value?(value) when is_number(value), do: true
  defp valid_header_value?(_value), do: false

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
    with {:ok, raw_base_url} <-
           resolve_string(opts, :base_url, "TYPESAFE_BASE_URL", get_env, @default_base_url),
         {:ok, default_model} <-
           resolve_string(opts, :default_model, "TYPESAFE_DEFAULT_MODEL", get_env, @default_model),
         {:ok, log_level} <- resolve_log_level(opts, get_env) do
      base_url = String.trim_trailing(raw_base_url, "/")
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
  end

  defp resolve_api_key(opts, get_env) do
    case opts |> Keyword.get(:api_key) |> blank_to_nil() do
      nil ->
        case safe_env_value(get_env, "TYPESAFE_API_KEY") do
          {:ok, nil} -> {:error, %TypeSafe.Error{message: "TYPESAFE_API_KEY is required."}}
          {:ok, value} -> {:ok, value}
          {:error, %TypeSafe.Error{}} = error -> error
        end

      value ->
        {:ok, value}
    end
  end

  defp resolve_string(opts, key, env_name, get_env, default) do
    case Keyword.get(opts, key) do
      nil ->
        case safe_env_value(get_env, env_name) do
          {:ok, nil} -> {:ok, default}
          {:ok, value} -> {:ok, value}
          {:error, %TypeSafe.Error{}} = error -> error
        end

      value ->
        {:ok, value}
    end
  end

  defp resolve_log_level(opts, get_env) do
    case Keyword.get(opts, :log_level) do
      nil ->
        case safe_env_value(get_env, "TYPESAFE_LOG_LEVEL") do
          {:ok, nil} -> {:ok, @default_log_level}
          {:ok, value} -> {:ok, Map.get(@log_levels, String.downcase(value), @default_log_level)}
          {:error, %TypeSafe.Error{}} = error -> error
        end

      value when is_atom(value) ->
        {:ok, value}
    end
  end

  # `get_env` is caller-supplied and only checked for arity (spec §4 B5); its
  # RETURN value is unchecked, so a working 1-arity function that returns a
  # non-string, non-nil value (e.g. `fn _ -> 123 end`) must fail here rather
  # than crash `blank_to_nil/1` downstream (spec §4 R4).
  defp safe_env_value(get_env, env_name) do
    case get_env.(env_name) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        {:ok, blank_to_nil(value)}

      _non_string ->
        {:error,
         %TypeSafe.Error{
           message: "get_env must return a string or nil (got a non-string value for #{env_name})"
         }}
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
