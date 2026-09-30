defmodule TypeSafe.Retry do
  # `Retry-After` / `retry-after-ms` parsing for `TypeSafe.Errors`, per
  # docs/spec.md §5. Pure: the clock is injected as `now_ms`. Internal
  # implementation detail behind `TypeSafe.Error.RateLimit.retry_after_ms`.
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
