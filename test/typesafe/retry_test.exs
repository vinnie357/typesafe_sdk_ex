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

  # §11 S3a #2, §5 "several values": the first value is used.
  test "first of several header values wins" do
    input = %{"retry-after" => ["2", "9"]}

    assert Retry.parse_retry_after(input, @now_ms) == 2000
  end

  # §11 S3a #3 (retry.test.ts:61-63).
  test "retry-after-ms is preferred over retry-after" do
    input = headers([{"retry-after-ms", "250"}, {"retry-after", "3"}])

    assert Retry.parse_retry_after(input, @now_ms) == 250
  end

  # §11 S3a #3: zero is a valid retry-after-ms (S3b's end-to-end tests send ms 0).
  test "retry-after-ms zero alone is 0, not invalid" do
    assert Retry.parse_retry_after(headers([{"retry-after-ms", "0"}]), @now_ms) == 0
  end

  # §11 S3a #3, §5 "several values": the first retry-after-ms value is used.
  test "first of several retry-after-ms values wins" do
    input = %{"retry-after-ms" => ["250", "900"]}

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

  # §11 S3a #5, §5 decision 4: RFC 850 and asctime, the other forms
  # :httpd_util.convert_request_date/1 accepts (RFC 9110 §5.6.7).
  test "RFC 850 and asctime HTTP dates are relative to the injected now" do
    rfc850 = headers([{"retry-after", "Wednesday, 21-Oct-26 07:28:05 GMT"}])
    asctime = headers([{"retry-after", "Wed Oct 21 07:28:05 2026"}])

    assert Retry.parse_retry_after(rfc850, @now_ms) == 5000
    assert Retry.parse_retry_after(asctime, @now_ms) == 5000
  end

  # §11 S3a #6 (retry.test.ts:71-76).
  test "garbage and negative values -> nil" do
    assert Retry.parse_retry_after(headers([{"retry-after", "soon"}]), @now_ms) == nil
    assert Retry.parse_retry_after(headers([{"retry-after", "-5"}]), @now_ms) == nil
    assert Retry.parse_retry_after(headers([{"retry-after-ms", "nope"}]), @now_ms) == nil
  end

  # §11 S3a #6, §5 decision 1 (deliberate JS deviation: Number("") is 0, which
  # would mean an immediate retry against a rate-limiting server).
  test "blank values -> nil for both headers" do
    for blank <- ["", "   "], name <- ["retry-after", "retry-after-ms"] do
      assert Retry.parse_retry_after(headers([{name, blank}]), @now_ms) == nil
    end
  end

  # §11 S3a #4 and #6, §5 decision 1: a blank ms is invalid, so it falls through.
  test "blank retry-after-ms falls through to a valid retry-after" do
    input = headers([{"retry-after-ms", "  "}, {"retry-after", "3"}])

    assert Retry.parse_retry_after(input, @now_ms) == 3000
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

  # §11 S3a #7, §5 decision 3: Kernel.round/1 rounds half away from zero.
  test "a 2.5 tie rounds up to 3" do
    result = Retry.parse_retry_after(headers([{"retry-after-ms", "2.5"}]), @now_ms)

    assert result == 3
    assert is_integer(result)
  end

  # §11 S3a #8 (new; §12 q15 — JS Number() accepts these, retry.ts:44).
  test "non-decimal numeric forms are rejected" do
    for raw <- ["0x10", "1e3"] do
      assert Retry.parse_retry_after(headers([{"retry-after", raw}]), @now_ms) == nil
    end
  end

  # §11 S3a #8, §5 decision 2: strict ^\d+(\.\d+)?$ after trimming. JS Number()
  # accepts each of these (deliberate deviation).
  test "loose decimal forms are rejected in both headers" do
    for raw <- [".5", "5.", "+5"], name <- ["retry-after", "retry-after-ms"] do
      assert Retry.parse_retry_after(headers([{name, raw}]), @now_ms) == nil
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

  # §11 S3a #9, HTTP-date branch: a 2015 date is in the past against any real
  # clock, so the result is 0. A from_response/1 that passed a wrong `now`
  # (0, or seconds instead of ms) would return a large positive number.
  test "Errors.from_response on a 429 with a past HTTP date has retry_after_ms 0" do
    response = %Req.Response{
      status: 429,
      headers: %{"retry-after" => ["Wed, 21 Oct 2015 07:28:00 GMT"]},
      body: ""
    }

    assert %TypeSafe.Error.RateLimit{retry_after_ms: 0} = Errors.from_response(response)
  end

  # §10 S3a AC(4), §12 q18: :inets must be a declared application so a release
  # bundles :httpd_util. Compilation in test env cannot detect its absence
  # (credo loads :inets); the app spec can.
  test ":inets is declared in the application spec" do
    assert :inets in Application.spec(:typesafe_sdk_ex, :applications)
  end

  # Gate 4 B1 (PR #4). The grammar ^\d+(\.\d+)?$ accepts arbitrarily long
  # digit strings. The parser returns them exact and does not cap them
  # (S3b's max_retry_after_ms ceiling does that later). Float.parse/1 and
  # float multiplication cannot represent these, so they must not be used.
  @huge_ms String.to_integer(String.duplicate("9", 309))

  test "oversize retry-after-ms stays an exact integer and does not raise" do
    input = headers([{"retry-after-ms", String.duplicate("9", 309)}])
    result = Retry.parse_retry_after(input, @now_ms)

    assert result == @huge_ms
    assert is_integer(result)
  end

  test "oversize retry-after seconds stay an exact integer and do not raise" do
    input = headers([{"retry-after", "1" <> String.duplicate("0", 306)}])
    result = Retry.parse_retry_after(input, @now_ms)

    assert result == 10 ** 309
    assert is_integer(result)
  end

  test "oversize retry-after seconds with a fraction are exact" do
    input = headers([{"retry-after", String.duplicate("9", 309) <> ".5"}])
    result = Retry.parse_retry_after(input, @now_ms)

    assert result == @huge_ms * 1000 + 500
    assert is_integer(result)
  end

  # Gate 4 B1: String.to_charlist/1 raises on invalid UTF-8.
  test "non-UTF-8 bytes in retry-after -> nil, never a raise" do
    assert Retry.parse_retry_after(headers([{"retry-after", <<0xFF, 0xFE>>}]), @now_ms) == nil
  end

  test "non-UTF-8 retry-after-ms falls through to a valid retry-after" do
    input = headers([{"retry-after-ms", <<0xFF, 0xFE>>}, {"retry-after", "3"}])

    assert Retry.parse_retry_after(input, @now_ms) == 3000
  end

  # Gate 4 B1 through the real error path: a 429 must stay a RateLimit struct.
  test "Errors.from_response on a 429 with oversize or non-UTF-8 values does not raise" do
    cases = [
      {%{"retry-after-ms" => [String.duplicate("9", 309)]}, @huge_ms},
      {%{"retry-after" => ["1" <> String.duplicate("0", 306)]}, 10 ** 309},
      {%{"retry-after" => [<<0xFF, 0xFE>>]}, nil}
    ]

    for {response_headers, expected} <- cases do
      response = %Req.Response{status: 429, headers: response_headers, body: ""}

      assert %TypeSafe.Error.RateLimit{retry_after_ms: ^expected} = Errors.from_response(response)
    end
  end
end
