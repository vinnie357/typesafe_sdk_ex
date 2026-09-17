defmodule TypeSafe.HTTP do
  @moduledoc """
  Req request construction, protected headers, and response handling (spec
  `docs/spec.md` §3, §9a). `TypeSafe.list_models/2` and `TypeSafe.system_one/3`
  delegate here; see their `@doc` for the full contract.
  """

  @doc """
  Builds the base `Req.Request` for a client: `base_url` plus `req_options`
  merged in, then `decode_body: false` and `retry: false` forced (SDK-owned,
  spec §3, §5 — `req_options` cannot re-enable either), then the
  `authorization` header. Used by `TypeSafe.Config.build/1`.
  """
  @spec new_client_req(String.t(), keyword(), String.t()) :: Req.Request.t()
  def new_client_req(base_url, req_options, api_key) do
    req_config =
      [base_url: base_url]
      |> Keyword.merge(req_options)
      |> Keyword.put(:decode_body, false)
      |> Keyword.put(:retry, false)

    req_config
    |> Req.new()
    |> Req.Request.put_header("authorization", "Bearer " <> api_key)
  end

  @doc "Lists available models — see `TypeSafe.list_models/2` for the full contract."
  @spec list_models(TypeSafe.Client.t(), keyword()) ::
          {:ok, [map()] | TypeSafe.with_response_result()} | {:error, Exception.t()}
  def list_models(%TypeSafe.Client{} = client, opts) do
    case Keyword.validate(opts, [:headers, :with_response]) do
      {:ok, opts} -> validate_and_list_models(client, opts)
      {:error, invalid_keys} -> {:error, invalid_options_error(invalid_keys)}
    end
  end

  @doc "Asks typed questions about state — see `TypeSafe.system_one/3` for the full contract."
  @spec system_one(TypeSafe.Client.t(), TypeSafe.request(), keyword()) ::
          {:ok, term() | TypeSafe.with_response_result()} | {:error, Exception.t()}
  def system_one(
        %TypeSafe.Client{} = client,
        %{state: state, questions: questions} = request,
        opts
      )
      when is_map(questions) do
    with {:ok, opts} <- Keyword.validate(opts, [:headers, :with_response]),
         :ok <- validate_call_opts(opts),
         {:ok, built_questions} <- TypeSafe.Questions.validate(questions) do
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

  defp validate_call_opts(opts) do
    case Keyword.fetch(opts, :with_response) do
      :error -> :ok
      {:ok, value} -> validate_predicate(is_boolean(value), "with_response must be a boolean")
    end
  end

  defp validate_predicate(true, _message), do: :ok
  defp validate_predicate(false, message), do: {:error, %TypeSafe.Error{message: message}}

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

  defp sdk_user_agent, do: "typesafe-sdk-ex/" <> TypeSafe.version()

  defp runtime_string do
    "elixir/#{System.version()} (otp/#{:erlang.system_info(:otp_release)})"
  end
end
