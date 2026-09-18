defmodule TypeSafe.Errors do
  # Status -> struct mapping, §6 message extraction, and transport-error
  # wrapping. `TypeSafe.HTTP` delegates here for every non-2xx response and
  # every transport failure. Internal implementation detail behind the
  # `TypeSafe` facade; the public surface is the `TypeSafe.Error.*` structs
  # this module returns, not this module itself.
  @moduledoc false

  @max_raw_body_in_message 200

  @doc "Builds the §6-mapped error struct for a non-2xx HTTP response."
  @spec from_response(Req.Response.t()) :: Exception.t()
  def from_response(%Req.Response{status: status} = response) do
    decoded_body = TypeSafe.HTTP.decode_body(response)
    request_id = request_id_from(response.headers)
    message = describe(status, decoded_body, response.body)

    build_struct(status, decoded_body, response.headers, request_id, message)
  end

  @doc """
  Builds `TypeSafe.Error.Timeout` for a `:timeout` transport failure, or
  `TypeSafe.Error.Connection` for any other transport failure.
  """
  @spec from_transport_error(Exception.t(), pos_integer()) :: Exception.t()
  def from_transport_error(%Req.TransportError{reason: :timeout}, timeout_ms) do
    %TypeSafe.Error.Timeout{
      message: "Request timed out after #{timeout_ms}ms.",
      timeout_ms: timeout_ms
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
      retry_after_ms: retry_after_ms_from(headers)
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

  defp request_id_from(headers) do
    case Map.get(headers, "x-typesafe-request-id", []) do
      [id | _] -> id
      [] -> nil
    end
  end

  defp retry_after_ms_from(headers) do
    case Map.get(headers, "retry-after", []) do
      [value | _] -> parse_retry_after_seconds(value)
      [] -> nil
    end
  end

  defp parse_retry_after_seconds(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1000
      _invalid -> nil
    end
  end

  # §6 message rules, in order: the format is "<status> <detail>", with
  # `describe/3` building that string and `extract_detail/1` finding the
  # detail (errors.ts:16-37).
  defp describe(status, decoded_body, raw_body) do
    case extract_detail(decoded_body) do
      {:ok, detail} -> "#{status} #{detail}"
      :error -> "#{status} #{fallback_detail(decoded_body, raw_body)}"
    end
  end

  defp fallback_detail(nil, _raw_body), do: "status code (no body)"
  defp fallback_detail(_decoded_body, raw_body) when is_binary(raw_body), do: truncate(raw_body)
  defp fallback_detail(_decoded_body, raw_body), do: truncate(inspect(raw_body))

  defp truncate(text) do
    case String.length(text) > @max_raw_body_in_message do
      true -> String.slice(text, 0, @max_raw_body_in_message) <> "…"
      false -> text
    end
  end

  # Rule 1: body is a (non-empty) string -> the string.
  defp extract_detail(body) when is_binary(body) and body != "", do: {:ok, body}
  defp extract_detail(body) when is_binary(body), do: :error
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

  defp loc_string(loc) when is_list(loc) do
    loc
    |> Enum.reject(&(&1 == "body"))
    |> Enum.map_join(".", &to_string/1)
  end

  defp loc_string(_loc), do: ""
end
