defmodule TypeSafe.Retry do
  # Retry engine, per ADR 0007 and ADR 0009: `Retry-After` / `retry-after-ms`
  # parsing (also behind `TypeSafe.Error.RateLimit.retry_after_ms`), the delay
  # formula, and the Req retry callback. The pure functions take their clock
  # and randomness as arguments. Internal implementation detail.
  @moduledoc false

  # Seconds between the Gregorian epoch and the Unix epoch.
  @unix_epoch_gregorian_seconds 62_167_219_200

  @doc """
  Returns the server-requested retry delay in whole milliseconds, or `nil`.

  `retry-after-ms` wins when valid; otherwise `retry-after` is read as decimal
  seconds or an HTTP date (relative to `now_ms`, floored at 0). The first
  value of each header is used.
  """
  @spec parse_retry_after(%{optional(String.t()) => [String.t()]}, integer()) ::
          non_neg_integer() | nil
  def parse_retry_after(headers, now_ms) do
    case decimal_to_ms(first_value(headers, "retry-after-ms"), 1) do
      nil -> parse_retry_after_header(first_value(headers, "retry-after"), now_ms)
      ms -> ms
    end
  end

  @doc """
  Returns the delay in whole milliseconds before retry number `attempt + 1`
  (`attempt` counts from 0).

  A parsed `Retry-After` is used exactly, with no jitter, when the policy
  respects it and it does not exceed `max_retry_after_ms`. Otherwise the delay
  is `min(backoff_initial_ms * 2^attempt, backoff_max_ms)` shortened by
  `random_fun.() * backoff_jitter` (a float in `[0.0, 1.0]`), rounded half away
  from zero. Integer arithmetic throughout, so no attempt number can raise, and
  nothing returned exceeds `max(max_retry_after_ms, backoff_max_ms)`.
  """
  @spec delay_ms(
          non_neg_integer(),
          %{optional(String.t()) => [String.t()]} | nil,
          TypeSafe.RetryPolicy.t(),
          (-> float())
        ) :: non_neg_integer()
  def delay_ms(attempt, headers, %TypeSafe.RetryPolicy{} = policy, random_fun) do
    case server_delay(headers, policy) do
      {:ok, ms} -> ms
      :none -> backoff_ms(attempt, policy, random_fun)
    end
  end

  defp server_delay(headers, %{respect_retry_after: true, max_retry_after_ms: max})
       when is_map(headers) do
    case parse_retry_after(headers, System.os_time(:millisecond)) do
      ms when is_integer(ms) and ms <= max -> {:ok, ms}
      _absent_or_over_ceiling -> :none
    end
  end

  defp server_delay(_headers, _policy), do: :none

  defp backoff_ms(attempt, policy, random_fun) do
    base = capped_backoff(policy.backoff_initial_ms, attempt, policy.backoff_max_ms)
    {numerator, denominator} = Float.ratio(1 - random_fun.() * policy.backoff_jitter)

    div(base * numerator * 2 + denominator, 2 * denominator)
  end

  # min(initial * 2^attempt, max) by repeated doubling, which stops as soon as
  # the cap is reached, so a huge attempt number costs a handful of steps.
  defp capped_backoff(value, _attempt, max) when value >= max, do: max
  defp capped_backoff(0, _attempt, _max), do: 0
  defp capped_backoff(value, 0, _max), do: value
  defp capped_backoff(value, attempt, max), do: capped_backoff(value * 2, attempt - 1, max)

  @doc """
  Req 2-arity `:retry` callback: `{:delay, ms}` to retry or `false` to stop.

  The policy comes from `request.private[:typesafe_retry_policy]` and the
  attempt from Req's `:req_retry_count`. A 2xx response is never retried, even
  when `http_statuses` lists it. A `%Req.TransportError{reason: :timeout}`
  follows `api_timeout_error`; any other exception follows
  `api_connection_error`.
  """
  @spec decide(Req.Request.t(), Req.Response.t() | Exception.t()) ::
          {:delay, non_neg_integer()} | false
  def decide(_request, %Req.Response{status: status}) when status in 200..299, do: false

  def decide(request, %Req.Response{status: status, headers: headers}) do
    schedule(request, headers, &MapSet.member?(&1.http_statuses, status))
  end

  def decide(request, %Req.TransportError{reason: :timeout}) do
    schedule(request, nil, & &1.api_timeout_error)
  end

  def decide(request, _exception), do: schedule(request, nil, & &1.api_connection_error)

  defp schedule(request, headers, retryable?) do
    policy = Req.Request.get_private(request, :typesafe_retry_policy)
    attempt = Req.Request.get_private(request, :req_retry_count, 0)

    case attempt < policy.max_retries and retryable?.(policy) do
      true -> {:delay, delay_ms(attempt, headers, policy, &:rand.uniform/0)}
      false -> false
    end
  end

  defp parse_retry_after_header(nil, _now_ms), do: nil

  defp parse_retry_after_header(value, now_ms) do
    case decimal_to_ms(value, 1000) do
      nil -> http_date_to_ms(String.trim(value), now_ms)
      ms -> ms
    end
  end

  @doc false
  @spec first_value(%{optional(String.t()) => [String.t()]}, String.t()) :: String.t() | nil
  def first_value(headers, name) do
    case Map.get(headers, name, []) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp decimal_to_ms(nil, _factor), do: nil

  # Exact integer arithmetic: a float would overflow or raise on oversize
  # digit strings. Rounds half up, which is half away from zero for
  # non-negative values. No cap: max_retry_after_ms belongs to the retry loop.
  defp decimal_to_ms(value, factor) do
    case Regex.run(~r/\A(\d+)(?:\.(\d+))?\z/, String.trim(value), capture: :all_but_first) do
      [whole] -> String.to_integer(whole) * factor
      [whole, fraction] -> whole_and_fraction_to_ms(whole, fraction, factor)
      nil -> nil
    end
  end

  defp whole_and_fraction_to_ms(whole, fraction, factor) do
    scale = Integer.pow(10, byte_size(fraction))
    rounded = div(String.to_integer(fraction) * factor * 2 + scale, 2 * scale)

    String.to_integer(whole) * factor + rounded
  end

  # Values that failed the decimal grammar ("soon", "-5", "1e3", "0x10", "")
  # are handed to the HTTP-date parser, which never sees a number.
  defp http_date_to_ms(value, now_ms) do
    with {date, time} <- convert_request_date(value),
         {:ok, naive} <- NaiveDateTime.from_erl({date, time}) do
      date_ms =
        (naive |> NaiveDateTime.to_gregorian_seconds() |> elem(0)) - @unix_epoch_gregorian_seconds

      max(0, date_ms * 1000 - now_ms)
    else
      _bad_date -> nil
    end
  end

  # restraint: :httpd_util.convert_request_date/1 raises FunctionClauseError on
  # short inputs instead of returning :bad_date; the raise is confined to this
  # call. Bytes, not chars, so a non-UTF-8 value cannot raise either. Replace
  # with a hand-written IMF/RFC 850/asctime parser if :inets is ever dropped.
  defp convert_request_date(value) do
    :httpd_util.convert_request_date(:binary.bin_to_list(value))
  rescue
    FunctionClauseError -> :bad_date
  end
end
