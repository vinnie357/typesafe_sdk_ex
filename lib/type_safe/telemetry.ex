defmodule TypeSafe.Telemetry do
  @moduledoc """
  `:telemetry` events for every HTTP attempt, and an opt-in default logger that
  prints them in the JS SDK's log format (ADR 0013).

  Attach `TypeSafe.attach_default_logger/1` once at startup for the log lines, or
  attach your own handler to the events below. Events run in the process that made
  the call, so a handler that raises is detached by `:telemetry` for the rest of the
  VM; keep handlers total.

  ## Events

  Every event carries the emitting client's resolved `log_level` in its metadata. The
  default logger filters each line against that level, so the level is per client.

  ### `[:typesafe, :attempt, :start]`

  Fired before each HTTP attempt, retries included.

  Measurements: `monotonic_time` and `system_time`, both in native time units.

  Metadata:

    * `request_number` - a VM-wide positive integer, the same for every attempt and
      retry of one call, different for every call.
    * `method` - `:get` or `:post`.
    * `path` - `"/v1/models"` or `"/v1/systemone"`.
    * `attempt` - `0` for the first attempt, `1` for the first retry, and so on.
    * `log_level` - the client's level.
    * At `log_level: :debug` only: `url` (without credentials in the URL), `headers`
      (Req's shape: lowercase name to list of values, credential headers redacted)
      and `body` (the JSON string sent, or `nil` for a `GET`).

  ### `[:typesafe, :attempt, :stop]`

  Fired when an attempt ends with a response or a transport error. Every start is
  followed by exactly one stop, except when the adapter raises something other than
  a pool timeout.

  Measurements: `duration` and `monotonic_time`, in native time units.

  Metadata: `request_number`, `method`, `path`, `attempt` and `log_level` as above,
  plus:

    * `status` - the HTTP status, or `nil` for a transport error.
    * `request_id` - the `x-typesafe-request-id` response header, or `nil`.
    * `error` - `nil` for a response of any status, otherwise the
      `TypeSafe.Error.Timeout` or `TypeSafe.Error.Connection` the call reports.
      `reason: :pool_timeout` is reported here too.
    * At `log_level: :debug` only, for a response: `body`, the decoded response body
      (the decoded error body for a non-2xx status).

  ### `[:typesafe, :request, :retry]`

  Fired after the stop of an attempt that the retry policy will repeat, before the
  delay.

  Measurements: `delay_ms`, the delay in milliseconds.

  Metadata: `request_number`, `method`, `path` and `log_level` as above, plus
  `attempt` (the attempt that failed), `retry` (the number of the retry about to
  run, from 1), `max_retries` (the effective total for this call) and `reason` (the
  HTTP status, or the `TypeSafe.Error.Timeout` or `TypeSafe.Error.Connection`).

  ## Redaction

  Credential headers (`authorization`, `proxy-authorization`, `x-api-key`, `cookie`,
  `set-cookie`) are redacted before the event is emitted. A value that starts with a
  letters-only word and a space keeps that word as a "scheme", so a secret of that
  shape is partly visible (`"LETTERSONLYSECRETKEY x"` becomes
  `"LETTERSONLYSECRETKEY ***"`). Any other header, such as a custom `default_headers`
  entry, is reported as given.
  The `%Req.Request{}` is never put in metadata. See `redact_headers/1`.
  """

  require Logger

  @start [:typesafe, :attempt, :start]
  @stop [:typesafe, :attempt, :stop]
  @retry [:typesafe, :request, :retry]
  @events [@start, @stop, @retry]

  @handler_id "typesafe-default-logger"
  @prefix "[typesafe-sdk] "

  @rank %{debug: 0, info: 1, warning: 2, error: 3, off: 4}
  @levels Map.keys(@rank)

  # Slots of the per-call :counters ref.
  @attempt_slot 1
  @started_slot 2

  @key_headers ["authorization", "proxy-authorization", "x-api-key"]
  @opaque_headers ["cookie", "set-cookie"]

  @doc false
  @spec new_call(TypeSafe.Client.t(), atom(), String.t()) :: map()
  def new_call(%TypeSafe.Client{} = client, method, path) do
    %{
      request_number: System.unique_integer([:positive, :monotonic]),
      log_level: client.log_level,
      timeout_ms: client.timeout,
      method: method,
      path: path,
      state: :counters.new(2, [])
    }
  end

  @doc false
  @spec start(Req.Request.t()) :: Req.Request.t()
  def start(request) do
    case Req.Request.get_private(request, :typesafe_telemetry) do
      %{state: state, log_level: level} = call ->
        attempt = Req.Request.get_private(request, :req_retry_count, 0)
        monotonic = System.monotonic_time()
        :counters.put(state, @attempt_slot, attempt)
        :counters.put(state, @started_slot, monotonic)

        metadata = Map.merge(base(call, attempt), start_detail(request, level))
        measurements = %{monotonic_time: monotonic, system_time: System.system_time()}
        :telemetry.execute(@start, measurements, metadata)

      _no_telemetry_state ->
        :ok
    end

    request
  rescue
    # Emission must never change a call's result.
    _error -> request
  end

  @doc false
  @spec attempt_finished(Req.Request.t(), Req.Response.t() | Exception.t(), term()) :: :ok
  def attempt_finished(request, result, decision) do
    case Req.Request.get_private(request, :typesafe_telemetry) do
      %{state: state} = call ->
        attempt = :counters.get(state, @attempt_slot)
        failure = emit_stop(call, attempt, result)
        emit_retry(call, attempt, failure, decision, request)

      _no_telemetry_state ->
        :ok
    end
  rescue
    _error -> :ok
  end

  @doc false
  @spec pool_timeout(map()) :: :ok
  def pool_timeout(call) do
    emit_stop(call, :counters.get(call.state, @attempt_slot), :pool_timeout)
    :ok
  rescue
    _error -> :ok
  end

  # Emits the stop for the attempt that is open, and closes it. Returns the status
  # or the error that ended the attempt, which is the retry event's reason.
  defp emit_stop(%{state: state} = call, attempt, result) do
    case :counters.get(state, @started_slot) do
      0 ->
        nil

      started ->
        :counters.put(state, @started_slot, 0)
        now = System.monotonic_time()
        {status, request_id, error} = outcome(call, result)
        detail = stop_detail(call.log_level, result)

        metadata =
          call
          |> base(attempt)
          |> Map.merge(%{status: status, request_id: request_id, error: error})
          |> Map.merge(detail)

        :telemetry.execute(@stop, %{duration: now - started, monotonic_time: now}, metadata)
        status || error
    end
  end

  defp emit_retry(call, attempt, reason, {:delay, delay_ms}, request) when reason != nil do
    max_retries =
      case Req.Request.get_private(request, :typesafe_retry_policy) do
        %{max_retries: max} -> max
        _no_policy -> nil
      end

    metadata =
      call
      |> base(attempt)
      |> Map.merge(%{retry: attempt + 1, max_retries: max_retries, reason: reason})

    :telemetry.execute(@retry, %{delay_ms: delay_ms}, metadata)
  end

  defp emit_retry(_call, _attempt, _reason, _decision, _request), do: :ok

  defp base(call, attempt) do
    %{
      request_number: call.request_number,
      method: call.method,
      path: call.path,
      attempt: attempt,
      log_level: call.log_level
    }
  end

  defp outcome(_call, %Req.Response{status: status, headers: headers}) do
    {status, TypeSafe.Retry.first_value(headers, "x-typesafe-request-id"), nil}
  end

  defp outcome(call, exception) do
    {nil, nil, TypeSafe.Errors.from_transport_error(exception, call.timeout_ms)}
  end

  # URL, headers and bodies exist in metadata at :debug only.
  defp start_detail(request, :debug) do
    %{
      url: url_string(request.url),
      headers: redact_headers(request.headers),
      body: body_string(request.body)
    }
  end

  defp start_detail(_request, _level), do: %{}

  defp stop_detail(:debug, %Req.Response{} = response) do
    %{body: TypeSafe.HTTP.decode_body(response)}
  end

  defp stop_detail(_level, _result), do: %{}

  defp url_string(%URI{} = uri), do: URI.to_string(%{uri | userinfo: nil})
  defp url_string(_other), do: nil

  # The SDK sends a binary today; iodata is converted so the event carries the JSON
  # string whatever Req was handed.
  defp body_string(body) when is_binary(body), do: body
  defp body_string(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp body_string(_other), do: nil

  @doc """
  Attaches the default logger, handler id `"typesafe-default-logger"`.

  Takes no options yet; an unknown key returns `{:error, %TypeSafe.Error{}}`.
  Returns `:ok` or `{:error, :already_exists}`, `:telemetry`'s own results.
  """
  @spec attach_default_logger(keyword()) ::
          :ok | {:error, :already_exists} | {:error, TypeSafe.Error.t()}
  def attach_default_logger(opts \\ [])

  def attach_default_logger([]) do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  def attach_default_logger(opts) when is_list(opts) do
    case Keyword.keyword?(opts) do
      true ->
        {:error,
         %TypeSafe.Error{
           message: "Unknown option(s): #{opts |> Keyword.keys() |> Enum.join(", ")}"
         }}

      false ->
        {:error,
         %TypeSafe.Error{message: "attach_default_logger/1 requires a keyword list of options"}}
    end
  end

  def attach_default_logger(_opts) do
    {:error,
     %TypeSafe.Error{message: "attach_default_logger/1 requires a keyword list of options"}}
  end

  @doc """
  Detaches the default logger. Returns `:ok` or `{:error, :not_found}`.
  """
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    Enum.each(log_lines(event, measurements, metadata), fn {level, line} ->
      Logger.log(level, @prefix <> line)
    end)
  rescue
    # `:telemetry` detaches a handler that raises, for the rest of the VM.
    _error -> :ok
  end

  @doc false
  @spec log_lines(list(), map(), map()) :: [{:debug | :info, String.t()}]
  def log_lines(
        event,
        measurements,
        %{request_number: number, method: method, path: path, log_level: level} = metadata
      )
      when level in @levels do
    tag = "##{number} #{method |> to_string() |> String.upcase()} #{path}"

    event
    |> lines(measurements, metadata, tag)
    |> Enum.filter(fn {line_level, _line} -> @rank[line_level] >= @rank[level] end)
  end

  def log_lines(_event, _measurements, _metadata), do: []

  defp lines(@start, _measurements, %{url: url, headers: headers, body: body}, tag) do
    [{:debug, "#{tag} -> #{url} " <> inspect(%{headers: headers, body: body})}]
  end

  defp lines(@stop, %{duration: duration}, %{status: status} = metadata, tag)
       when is_integer(status) and is_integer(duration) do
    request_id =
      case Map.get(metadata, :request_id) do
        id when is_binary(id) and id != "" -> " (request #{id})"
        _no_request_id -> ""
      end

    [{:info, "#{tag} <- #{status} in #{ms(duration)}ms#{request_id}"}] ++
      body_lines(metadata, status, tag)
  end

  defp lines(@stop, %{duration: duration}, %{error: %TypeSafe.Error.Timeout{}}, tag)
       when is_integer(duration) do
    [{:info, "#{tag} timed out after #{ms(duration)}ms"}]
  end

  defp lines(@stop, %{duration: duration}, %{error: error}, tag)
       when is_integer(duration) and error != nil do
    [{:info, "#{tag} connection error after #{ms(duration)}ms " <> inspect(error)}]
  end

  defp lines(
         @retry,
         %{delay_ms: delay_ms},
         %{retry: retry, max_retries: max, reason: reason},
         tag
       ) do
    [
      {:info,
       "#{tag} retrying in #{delay_ms}ms (retry #{retry}/#{max}) after #{reason_text(reason)}"}
    ]
  end

  defp lines(_event, _measurements, _metadata, _tag), do: []

  defp body_lines(%{body: body}, status, tag) do
    label =
      case status in 200..299 do
        true -> "body"
        false -> "error body"
      end

    [{:debug, "#{tag} <- #{label} " <> inspect(body)}]
  end

  defp body_lines(_metadata, _status, _tag), do: []

  defp ms(native), do: System.convert_time_unit(native, :native, :millisecond)

  defp reason_text(status) when is_integer(status), do: Integer.to_string(status)
  defp reason_text(%{message: message}) when is_binary(message), do: message
  defp reason_text(other), do: inspect(other)

  @doc false
  @spec redact_headers(map()) :: map()
  def redact_headers(headers) when is_map(headers) do
    Map.new(headers, fn {name, values} -> {name, redact_values(header_kind(name), values)} end)
  end

  def redact_headers(_other), do: %{}

  defp header_kind(name) when is_binary(name) do
    case String.downcase(name) do
      lower when lower in @key_headers -> :key
      lower when lower in @opaque_headers -> :opaque
      _other -> :plain
    end
  end

  defp header_kind(_name), do: :plain

  defp redact_values(:plain, values), do: values
  defp redact_values(kind, values) when is_list(values), do: Enum.map(values, &mask(kind, &1))
  defp redact_values(kind, value), do: mask(kind, value)

  defp mask(:key, value) when is_binary(value), do: redact_key(value)
  defp mask(_kind, _value), do: "***"

  # JS logging.ts:53-58, with one deviation (ADR 0013 decision 15): the first
  # whitespace-separated word is a scheme only when it is letters alone. Any other
  # value, such as a dashed key followed by a space, is masked whole, so no part of
  # it is echoed as a "scheme". The secret keeps its last four characters only when
  # it is longer than eight.
  defp redact_key(value) do
    with true <- String.contains?(value, " "),
         [scheme, secret | _rest] <- String.split(value, ~r/\s+/),
         true <- Regex.match?(~r/^[A-Za-z]+$/, scheme) do
      scheme <> " ***" <> tail(secret)
    else
      _no_scheme -> "***" <> tail(value)
    end
  end

  defp tail(secret) do
    case String.length(secret) > 8 do
      true -> String.slice(secret, -4, 4)
      false -> ""
    end
  end
end
