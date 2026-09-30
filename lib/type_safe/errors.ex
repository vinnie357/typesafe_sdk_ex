defmodule TypeSafe.Errors do
  # Status -> struct mapping, ADR 0006 message extraction, and transport-error
  # wrapping. `TypeSafe.HTTP` delegates here for every non-2xx response and
  # every transport failure. Internal implementation detail behind the
  # `TypeSafe` facade; the public surface is the `TypeSafe.Error.*` structs
  # this module returns, not this module itself.
  @moduledoc false

  @max_raw_body_in_message 200

  @doc "Builds the error struct for a non-2xx HTTP response (ADR 0006)."
  @spec from_response(Req.Response.t()) :: Exception.t()
  def from_response(%Req.Response{status: status} = response) do
    decoded_body = TypeSafe.HTTP.decode_body(response)
    request_id = TypeSafe.Retry.first_value(response.headers, "x-typesafe-request-id")
    message = describe(status, decoded_body, response.body)

    build_struct(status, decoded_body, response.headers, request_id, message)
  end

  @doc """
  Builds `TypeSafe.Error.Timeout` for a `:timeout` transport failure, or
  `TypeSafe.Error.Connection` for any other transport failure, including the
  `:pool_timeout` marker `TypeSafe.HTTP` returns when Finch's pool is exhausted.
  """
  @spec from_transport_error(Exception.t() | :pool_timeout, pos_integer()) :: Exception.t()
  def from_transport_error(%Req.TransportError{reason: :timeout}, timeout_ms) do
    %TypeSafe.Error.Timeout{
      message: "Request timed out after #{timeout_ms}ms.",
      timeout_ms: timeout_ms
    }
  end

  def from_transport_error(:pool_timeout, _timeout_ms) do
    %TypeSafe.Error.Connection{
      message:
        "Connection error: connection pool exhausted " <>
          "(no connection available within the pool timeout)",
      reason: :pool_timeout
    }
  end

  def from_transport_error(exception, _timeout_ms) do
    %TypeSafe.Error.Connection{
      message: "Connection error: " <> Exception.message(exception),
      reason: transport_reason(exception)
    }
  end

  defp transport_reason(%Req.TransportError{reason: reason}), do: reason
  defp transport_reason(_exception), do: nil

  defp build_struct(429, decoded_body, headers, request_id, message) do
    %TypeSafe.Error.RateLimit{
      status: 429,
      body: decoded_body,
      headers: headers,
      request_id: request_id,
      message: message,
      retry_after_ms: TypeSafe.Retry.parse_retry_after(headers, System.os_time(:millisecond))
    }
  end

  defp build_struct(status, decoded_body, headers, request_id, message) do
    struct(struct_for(status), %{
      status: status,
      body: decoded_body,
      headers: headers,
      request_id: request_id,
      message: message
    })
  end

  defp struct_for(400), do: TypeSafe.Error.BadRequest
  defp struct_for(401), do: TypeSafe.Error.Authentication
  defp struct_for(403), do: TypeSafe.Error.PermissionDenied
  defp struct_for(404), do: TypeSafe.Error.NotFound
  defp struct_for(422), do: TypeSafe.Error.UnprocessableEntity
  defp struct_for(status) when status >= 500, do: TypeSafe.Error.InternalServer
  defp struct_for(_status), do: TypeSafe.Error.API

  # ADR 0006 message rules, in order: the format is "<status> <detail>", with
  # `describe/3` building that string and `extract_detail/1` finding the
  # detail (errors.ts:16-37).
  # An empty detail counts as none (errors.ts:62) but still ends the search
  # (errors.ts:20-24): the fallback is keyed on the RAW body, so a JSON `null`
  # body (decoded to `nil`) reads "null", not "no body".
  defp describe(status, decoded_body, raw_body) do
    case extract_detail(decoded_body) do
      {:ok, detail} when detail != "" -> "#{status} #{detail}"
      _no_detail -> "#{status} #{fallback_detail(raw_body)}"
    end
  end

  defp fallback_detail(raw_body) when raw_body in [nil, ""], do: "status code (no body)"
  defp fallback_detail(raw_body) when is_binary(raw_body), do: truncate(raw_body)
  defp fallback_detail(raw_body), do: truncate(inspect(raw_body))

  defp truncate(text) do
    case String.length(text) > @max_raw_body_in_message do
      true -> String.slice(text, 0, @max_raw_body_in_message) <> "…"
      false -> text
    end
  end

  # Rule 1: body is a string -> the string.
  defp extract_detail(body) when is_binary(body), do: {:ok, body}
  # Rule 2: `error` is a string.
  defp extract_detail(%{"error" => error}) when is_binary(error), do: {:ok, error}
  # Rule 3: `error.message`.
  defp extract_detail(%{"error" => %{"message" => message}}) when is_binary(message),
    do: {:ok, message}

  # Rule 4: top-level `message`.
  defp extract_detail(%{"message" => message}) when is_binary(message), do: {:ok, message}
  # Rule 5: `detail` is a string.
  defp extract_detail(%{"detail" => detail}) when is_binary(detail), do: {:ok, detail}
  # Rule 6: `detail.message`.
  defp extract_detail(%{"detail" => %{"message" => message}}) when is_binary(message),
    do: {:ok, message}

  # Rule 7: `detail` is a list of validation errors.
  defp extract_detail(%{"detail" => detail}) when is_list(detail) do
    case describe_validation_errors(detail) do
      "" -> :error
      described -> {:ok, described}
    end
  end

  defp extract_detail(_other), do: :error

  defp describe_validation_errors(errors) do
    errors
    |> Enum.flat_map(&describe_validation_error/1)
    |> Enum.join("; ")
  end

  defp describe_validation_error(%{"msg" => msg} = entry) when is_binary(msg) do
    case loc_string(Map.get(entry, "loc")) do
      "" -> [msg]
      loc -> ["#{loc}: #{msg}"]
    end
  end

  defp describe_validation_error(_entry), do: []

  # Mirrors `loc.filter((x) => x !== "body").join(".")` (errors.ts:31, ADR 0006
  # decision 14): "body" is dropped at the top level only, and each element
  # renders as JS `Array#join` does, so no JSON value raises.
  defp loc_string(loc) when is_list(loc) do
    loc
    |> Enum.reject(&(&1 == "body"))
    |> js_join(".")
  end

  defp loc_string(_loc), do: ""

  defp js_join(list, separator), do: Enum.map_join(list, separator, &js_string/1)

  defp js_string(nil), do: ""
  defp js_string(object) when is_map(object), do: "[object Object]"
  defp js_string(list) when is_list(list), do: js_join(list, ",")
  defp js_string(scalar), do: to_string(scalar)
end
