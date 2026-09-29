defmodule TypeSafe.RetryTest do
  use ExUnit.Case, async: true

  # docs/spec.md §11 S3a (test list 1-9), §5 "Retry-After parsing", §12 q15.
  # `parse_retry_after/2` is pure: time is injected through `now_ms`, and no
  # test here reads the clock, sleeps, or touches the network.
  # Header shape is Req's: lowercase names mapping to lists of values.

  alias TypeSafe.Errors
  alias TypeSafe.Retry

  # 2026-10-21T07:28:00Z, matching `retry.test.ts:66`.
  @now_ms DateTime.to_unix(~U[2026-10-21 07:28:00Z], :millisecond)

  defp headers(pairs), do: Map.new(pairs, fn {name, value} -> {name, [value]} end)

  # §11 S3a #1 (retry.test.ts:72).
  test "no headers -> nil" do
    assert Retry.parse_retry_after(%{}, @now_ms) == nil
    assert Retry.parse_retry_after(%{"retry-after" => []}, @now_ms) == nil
    assert Retry.parse_retry_after(%{"retry-after-ms" => []}, @now_ms) == nil
  end

  # §11 S3a #2 (retry.test.ts:55-59); trimming per §5 "trimmed non-negative decimals".
  test "retry-after seconds, including zero and decimals" do
    assert Retry.parse_retry_after(headers([{"retry-after", "3"}]), @now_ms) == 3000
    assert Retry.parse_retry_after(headers([{"retry-after", "0"}]), @now_ms) == 0
    assert Retry.parse_retry_after(headers([{"retry-after", "1.5"}]), @now_ms) == 1500
    assert Retry.parse_retry_after(headers([{"retry-after", " 3 "}]), @now_ms) == 3000
  end

  # §11 S3a #3 (retry.test.ts:61-63).
  test "retry-after-ms is preferred over retry-after" do
    input = headers([{"retry-after-ms", "250"}, {"retry-after", "3"}])

    assert Retry.parse_retry_after(input, @now_ms) == 250
  end

  # §11 S3a #4 (new; retry.ts:39-45 returns ms only when finite and >= 0,
  # otherwise falls through to retry-after).
  test "invalid retry-after-ms falls through to retry-after" do
    for bad_ms <- ["nope", "-1"] do
      input = headers([{"retry-after-ms", bad_ms}, {"retry-after", "3"}])

      assert Retry.parse_retry_after(input, @now_ms) == 3000
    end
  end

  # §11 S3a #5 (retry.test.ts:65-69).
  test "HTTP date is relative to the injected now" do
    future = headers([{"retry-after", "Wed, 21 Oct 2026 07:28:05 GMT"}])
    past = headers([{"retry-after", "Wed, 21 Oct 2026 07:27:00 GMT"}])

    assert Retry.parse_retry_after(future, @now_ms) == 5000
    assert Retry.parse_retry_after(past, @now_ms) == 0
  end

  # §11 S3a #6 (retry.test.ts:71-76).
  test "garbage and negative values -> nil" do
    assert Retry.parse_retry_after(headers([{"retry-after", "soon"}]), @now_ms) == nil
    assert Retry.parse_retry_after(headers([{"retry-after", "-5"}]), @now_ms) == nil
    assert Retry.parse_retry_after(headers([{"retry-after-ms", "nope"}]), @now_ms) == nil
  end

  # §11 S3a #7 (new; Req accepts only an integer {:delay, _}, steps.ex:1803).
  test "fractional milliseconds are rounded to an integer" do
    ms_result = Retry.parse_retry_after(headers([{"retry-after-ms", "10.4"}]), @now_ms)
    seconds_result = Retry.parse_retry_after(headers([{"retry-after", "1.0004"}]), @now_ms)

    assert ms_result == 10
    assert is_integer(ms_result)
    assert seconds_result == 1000
    assert is_integer(seconds_result)
  end

  # §11 S3a #8 (new; §12 q15 — JS Number() accepts these, retry.ts:44).
  test "non-decimal numeric forms are rejected" do
    for raw <- ["0x10", "1e3"] do
      assert Retry.parse_retry_after(headers([{"retry-after", raw}]), @now_ms) == nil
    end
  end

  # §11 S3a #9 (errors.ts:94, reliability.test.ts:538-545). Pure: builds the
  # error straight from a response, with no client and no HTTP.
  test "Errors.from_response on a 429 builds retry_after_ms through the parser" do
    ms_response = %Req.Response{
      status: 429,
      headers: %{"retry-after-ms" => ["1500"]},
      body: ""
    }

    seconds_response = %Req.Response{
      status: 429,
      headers: %{"retry-after" => ["1.5"]},
      body: ""
    }

    assert %TypeSafe.Error.RateLimit{retry_after_ms: 1500} = Errors.from_response(ms_response)

    assert %TypeSafe.Error.RateLimit{retry_after_ms: 1500} =
             Errors.from_response(seconds_response)
  end
end
