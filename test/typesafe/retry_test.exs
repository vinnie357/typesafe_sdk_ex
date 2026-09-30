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

  # ---------------------------------------------------------------------------
  # S3b pure tests (docs/spec.md §11 S3b #10-26, 18a, 18b). No HTTP, no clock
  # reads that change an expected value, no sleeping. `delay_ms/4` takes its
  # randomness as a function returning a float in [0.0, 1.0]; tests pass a
  # constant. `decide/2` reads the policy and attempt from the request the way
  # spec §5 says (`:typesafe_retry_policy`, `:req_retry_count`).
  # ---------------------------------------------------------------------------

  alias TypeSafe.Error
  alias TypeSafe.RetryPolicy

  # Zero jitter makes `decide/2` deterministic (§11 S3b #23).
  @zero_jitter %RetryPolicy{backoff_jitter: 0}

  defp request_for(policy, retry_count \\ 0) do
    Req.new()
    |> Req.Request.put_private(:typesafe_retry_policy, policy)
    |> Req.Request.put_private(:req_retry_count, retry_count)
  end

  defp response_with(status, header_pairs \\ []) do
    Req.Response.new(status: status, headers: header_pairs, body: "")
  end

  defp merge_error_message(overrides) do
    assert {:error, %Error{message: message}} = RetryPolicy.merge(%RetryPolicy{}, overrides)
    message
  end

  describe "RetryPolicy.merge/2" do
    # §11 S3b #10
    test "merge with [] returns the same policy" do
      policy = %RetryPolicy{max_retries: 5, backoff_jitter: 0.5}

      assert RetryPolicy.merge(policy, []) == {:ok, policy}
      assert RetryPolicy.merge(%RetryPolicy{}, []) == {:ok, %RetryPolicy{}}
    end

    # §11 S3b #11 (reliability.test.ts:195-199, 383-400)
    test "merge is field by field" do
      assert {:ok, merged} = RetryPolicy.merge(%RetryPolicy{}, max_retries: 7, backoff_jitter: 0)
      assert merged == %{%RetryPolicy{} | max_retries: 7, backoff_jitter: 0}

      base = %RetryPolicy{max_retries: 5, api_timeout_error: true}
      assert {:ok, merged} = RetryPolicy.merge(base, backoff_initial_ms: 10)
      assert merged == %{base | backoff_initial_ms: 10}
    end

    # §11 S3b #12
    test "http_statuses accepts a list, a Range, or a MapSet, stored as a MapSet" do
      assert {:ok, %RetryPolicy{http_statuses: from_list}} =
               RetryPolicy.merge(%RetryPolicy{}, http_statuses: [503, 409, 503])

      assert from_list == MapSet.new([409, 503])

      assert {:ok, %RetryPolicy{http_statuses: from_range}} =
               RetryPolicy.merge(%RetryPolicy{}, http_statuses: 500..502)

      assert from_range == MapSet.new([500, 501, 502])

      assert {:ok, %RetryPolicy{http_statuses: from_set}} =
               RetryPolicy.merge(%RetryPolicy{}, http_statuses: MapSet.new([418]))

      assert from_set == MapSet.new([418])

      assert {:ok, %RetryPolicy{http_statuses: empty}} =
               RetryPolicy.merge(%RetryPolicy{}, http_statuses: [])

      assert empty == MapSet.new()
    end

    # §11 S3b #13 (reliability.test.ts:168-180, 402-421). The message form is
    # the one §4 spells out.
    test "validation names the field with the spec message form" do
      assert merge_error_message(max_retries: -1) ==
               "retry.max_retries must be a non-negative integer, got -1"
    end

    test "validation names each bad field" do
      bad_values = [
        max_retries: -1,
        max_retries: 1.5,
        max_retries: nil,
        backoff_initial_ms: -1,
        backoff_max_ms: -1,
        backoff_jitter: 1.5,
        backoff_jitter: -0.1,
        max_retry_after_ms: -1,
        http_statuses: [503, 42],
        http_statuses: [99],
        http_statuses: [1000],
        http_statuses: [500.5],
        http_statuses: 503,
        respect_retry_after: "yes",
        api_connection_error: nil,
        api_timeout_error: 1
      ]

      for {field, value} <- bad_values do
        message = merge_error_message([{field, value}])

        assert message =~ "retry.#{field}",
               "expected #{inspect({field, value})} to be rejected naming retry.#{field}, got: #{message}"
      end
    end

    test "an unknown key is named" do
      assert merge_error_message(bogus: 1) =~ "bogus"
    end

    test "a non-keyword value is rejected without raising" do
      for bad <- [nil, :bogus, [1, 2], "max_retries: 1"] do
        assert {:error, %Error{message: message}} = RetryPolicy.merge(%RetryPolicy{}, bad)
        assert message =~ "retry"
      end
    end

    # §11 S3b #14 (reliability.test.ts:411-412)
    test "boundaries are accepted" do
      assert {:ok, zeros} =
               RetryPolicy.merge(%RetryPolicy{},
                 backoff_initial_ms: 0,
                 backoff_max_ms: 0,
                 backoff_jitter: 0
               )

      assert {zeros.backoff_initial_ms, zeros.backoff_max_ms, zeros.backoff_jitter} == {0, 0, 0}

      assert {:ok, edge} =
               RetryPolicy.merge(%RetryPolicy{}, backoff_jitter: 1, max_retry_after_ms: 0)

      assert {edge.backoff_jitter, edge.max_retry_after_ms} == {1, 0}

      assert {:ok, low} = RetryPolicy.merge(%RetryPolicy{}, backoff_jitter: 0.0)
      assert low.backoff_jitter == 0

      assert {:ok, high} = RetryPolicy.merge(%RetryPolicy{}, backoff_jitter: 1.0)
      assert high.backoff_jitter == 1

      assert {:ok, %RetryPolicy{max_retries: 0}} =
               RetryPolicy.merge(%RetryPolicy{}, max_retries: 0)

      assert {:ok, %RetryPolicy{http_statuses: statuses}} =
               RetryPolicy.merge(%RetryPolicy{}, http_statuses: [100, 999])

      assert statuses == MapSet.new([100, 999])
    end

    # §5 default policy, operator decision q20: timeout retries are opt-in.
    test "the default policy does not retry timeouts" do
      assert %RetryPolicy{}.api_timeout_error == false
      assert %RetryPolicy{}.api_connection_error == true
    end
  end

  describe "delay_ms/4" do
    # §11 S3b #15 (retry.test.ts:84-88)
    test "exponential backoff with zero jitter" do
      delays = for attempt <- 0..5, do: Retry.delay_ms(attempt, nil, @zero_jitter, fn -> 0.5 end)

      assert delays == [500, 1000, 2000, 4000, 5000, 5000]
      assert Enum.all?(delays, &is_integer/1)

      # An empty header map behaves like no headers.
      assert Retry.delay_ms(2, %{}, @zero_jitter, fn -> 0.5 end) == 2000
    end

    test "a huge attempt number is capped at backoff_max_ms and does not raise" do
      assert Retry.delay_ms(2000, nil, @zero_jitter, fn -> 0.0 end) == 5000
    end

    # §11 S3b #16 (retry.test.ts:90-93)
    test "jitter shaves at most the configured fraction" do
      assert Retry.delay_ms(0, nil, %RetryPolicy{}, fn -> 1.0 end) == 375
      assert Retry.delay_ms(1, nil, %RetryPolicy{}, fn -> 0.5 end) == 875
      assert Retry.delay_ms(0, nil, %RetryPolicy{}, fn -> 0.0 end) == 500
    end

    # §11 S3b #17 (retry.test.ts:95-98): exact, with no jitter applied even at
    # random 1.0.
    test "Retry-After is honored exactly" do
      assert Retry.delay_ms(0, %{"retry-after" => ["2"]}, %RetryPolicy{}, fn -> 1.0 end) == 2000
      assert Retry.delay_ms(0, %{"retry-after-ms" => ["10"]}, %RetryPolicy{}, fn -> 1.0 end) == 10
    end

    # §11 S3b #18 (retry.test.ts:100-105)
    test "Retry-After above max_retry_after_ms falls back to backoff" do
      policy = %RetryPolicy{}

      assert Retry.delay_ms(0, %{"retry-after" => ["61"]}, policy, fn -> 0.0 end) == 500
      assert Retry.delay_ms(0, %{"retry-after" => ["60"]}, policy, fn -> 0.0 end) == 60_000
      assert Retry.delay_ms(0, %{"retry-after-ms" => ["60000"]}, policy, fn -> 0.0 end) == 60_000
      assert Retry.delay_ms(0, %{"retry-after-ms" => ["60001"]}, policy, fn -> 1.0 end) == 375
    end

    # §11 S3b #19 (retry.test.ts:107-114)
    test "policy initial, cap, and jitter are respected" do
      capped = %RetryPolicy{backoff_initial_ms: 100, backoff_max_ms: 350, backoff_jitter: 0}
      delays = for attempt <- 0..3, do: Retry.delay_ms(attempt, nil, capped, fn -> 0.5 end)
      assert delays == [100, 200, 350, 350]

      assert Retry.delay_ms(0, nil, %RetryPolicy{backoff_initial_ms: 50, backoff_jitter: 0}, fn ->
               0.5
             end) == 50

      assert Retry.delay_ms(0, nil, @zero_jitter, fn -> 1.0 end) == 500
    end

    # §11 S3b #20 (retry.test.ts:116-119)
    test "respect_retry_after false ignores the header" do
      policy = %RetryPolicy{respect_retry_after: false}

      assert Retry.delay_ms(0, %{"retry-after-ms" => ["10"]}, policy, fn -> 0.0 end) == 500
      assert Retry.delay_ms(0, %{"retry-after" => ["2"]}, policy, fn -> 0.0 end) == 500
    end

    # §11 S3b #21 (retry.test.ts:121-125)
    test "max_retry_after_ms of 1000 is the ceiling, inclusive" do
      policy = %RetryPolicy{max_retry_after_ms: 1000}

      assert Retry.delay_ms(0, %{"retry-after" => ["1"]}, policy, fn -> 0.0 end) == 1000
      assert Retry.delay_ms(0, %{"retry-after" => ["2"]}, policy, fn -> 0.0 end) == 500
      assert Retry.delay_ms(0, %{"retry-after-ms" => ["1000"]}, policy, fn -> 0.0 end) == 1000
      assert Retry.delay_ms(0, %{"retry-after-ms" => ["1001"]}, policy, fn -> 0.0 end) == 500
    end

    # An unparseable header carries no delay, so backoff applies.
    test "garbage Retry-After falls back to backoff" do
      assert Retry.delay_ms(1, %{"retry-after" => ["soon"]}, @zero_jitter, fn -> 0.0 end) == 1000
    end
  end

  # §5 "Delay ceiling on the delay path" (lead decision 2026-09-29): the parser
  # returns uncapped values, so the ceiling must be applied in delay_ms/4 before
  # anything reaches Req's {:delay, _}.
  describe "delay ceiling" do
    @year_9999 "Fri, 31 Dec 9999 23:59:59 GMT"
    @huge_headers [
      %{"retry-after" => [@year_9999]},
      %{"retry-after" => [String.duplicate("9", 309)]},
      %{"retry-after-ms" => [String.duplicate("9", 309)]}
    ]

    # §11 S3b #18a
    test "huge Retry-After falls back to backoff in delay_ms/4" do
      for headers <- @huge_headers do
        delay = Retry.delay_ms(0, headers, @zero_jitter, fn -> 0.0 end)

        assert delay == 500, "expected backoff for #{inspect(headers)}, got #{delay}"
        assert is_integer(delay)
      end
    end

    # §11 S3b #18a, through decide/2, which is what Req actually receives.
    test "huge Retry-After never reaches Req as a delay above the ceiling" do
      policy = %{@zero_jitter | max_retries: 5}

      for headers <- @huge_headers, retry_count <- 0..3 do
        response = Req.Response.new(status: 429, headers: headers, body: "")
        expected_backoff = Enum.at([500, 1000, 2000, 4000], retry_count)

        assert {:delay, delay} = Retry.decide(request_for(policy, retry_count), response)
        assert delay == expected_backoff
        assert delay <= max(policy.max_retry_after_ms, policy.backoff_max_ms)
      end
    end

    # §11 S3b #18b
    test "no delay exceeds max(max_retry_after_ms, backoff_max_ms), and a header within the ceiling is exact" do
      header_sets =
        [
          %{"retry-after" => ["0"]},
          %{"retry-after" => ["1"]},
          %{"retry-after" => ["1.5"]},
          %{"retry-after" => ["2"]},
          %{"retry-after" => ["61"]},
          %{"retry-after" => ["3600"]},
          %{"retry-after" => ["soon"]},
          %{"retry-after" => ["Wed, 21 Oct 2015 07:28:00 GMT"]},
          %{"retry-after-ms" => ["0"]},
          %{"retry-after-ms" => ["150"]},
          %{"retry-after-ms" => ["999999"]}
        ] ++ @huge_headers

      # backoff_max_ms below, equal to, and above max_retry_after_ms.
      ceilings = [{1000, 200}, {1000, 1000}, {100, 5000}]

      for {max_retry_after_ms, backoff_max_ms} <- ceilings,
          headers <- header_sets do
        policy = %RetryPolicy{
          max_retry_after_ms: max_retry_after_ms,
          backoff_max_ms: backoff_max_ms,
          backoff_jitter: 0
        }

        parsed = Retry.parse_retry_after(headers, System.os_time(:millisecond))
        delay = Retry.delay_ms(0, headers, policy, fn -> 0.0 end)

        expected =
          case parsed do
            ms when is_integer(ms) and ms <= max_retry_after_ms -> ms
            _over_or_absent -> min(500, backoff_max_ms)
          end

        assert delay == expected,
               "policy #{inspect({max_retry_after_ms, backoff_max_ms})}, headers " <>
                 "#{inspect(headers)}: expected #{expected}, got #{delay}"

        assert delay <= max(max_retry_after_ms, backoff_max_ms)
      end
    end
  end

  describe "decide/2" do
    # §11 S3b #22
    test "a 2xx response is never retried" do
      for status <- [200, 201, 204] do
        assert Retry.decide(request_for(@zero_jitter), response_with(status)) == false
      end
    end

    # §11 S3b #23 (retry.test.ts:38-44)
    test "default statuses retry with the attempt-0 backoff, others do not" do
      for status <- [408, 429, 500, 502, 503, 504, 529, 599] do
        assert Retry.decide(request_for(@zero_jitter), response_with(status)) == {:delay, 500},
               "status #{status} should retry"
      end

      for status <- [400, 401, 403, 404, 409, 422, 600] do
        assert Retry.decide(request_for(@zero_jitter), response_with(status)) == false,
               "status #{status} should not retry"
      end
    end

    test "the delay follows the attempt counted by :req_retry_count" do
      policy = %{@zero_jitter | max_retries: 5}

      delays =
        for count <- 0..4 do
          {:delay, delay} = Retry.decide(request_for(policy, count), response_with(503))
          delay
        end

      assert delays == [500, 1000, 2000, 4000, 5000]
    end

    # §11 S3b #24 (retry.test.ts:46-51)
    test "custom and empty status sets" do
      only_409 = %{@zero_jitter | http_statuses: MapSet.new([409])}
      assert Retry.decide(request_for(only_409), response_with(409)) == {:delay, 500}
      assert Retry.decide(request_for(only_409), response_with(503)) == false

      none = %{@zero_jitter | http_statuses: MapSet.new()}
      assert Retry.decide(request_for(none), response_with(503)) == false
    end

    # §11 S3b #25
    test "a 429 with Retry-After 2 delays exactly 2000ms; a 400 does not retry" do
      request = request_for(%RetryPolicy{})

      assert Retry.decide(request, response_with(429, [{"retry-after", "2"}])) == {:delay, 2000}
      assert Retry.decide(request, response_with(400, [{"retry-after", "2"}])) == false
    end

    # §11 S3b #26, transport errors (client.ts:150-154, 383-384); q20.
    test "a :timeout is not retried by default and is retried with api_timeout_error: true" do
      timeout = %Req.TransportError{reason: :timeout}

      assert Retry.decide(request_for(%{%RetryPolicy{} | backoff_jitter: 0}), timeout) == false

      opted_in = %{@zero_jitter | api_timeout_error: true}
      assert Retry.decide(request_for(opted_in), timeout) == {:delay, 500}
    end

    test ":closed and other exceptions follow api_connection_error" do
      closed = %Req.TransportError{reason: :closed}
      refused = %Req.TransportError{reason: :econnrefused}
      other = RuntimeError.exception("boom")

      for exception <- [closed, refused, other] do
        assert Retry.decide(request_for(@zero_jitter), exception) == {:delay, 500}

        assert Retry.decide(
                 request_for(%{@zero_jitter | api_connection_error: false}),
                 exception
               ) == false
      end

      # api_connection_error does not govern timeouts, nor api_timeout_error the rest.
      assert Retry.decide(
               request_for(%{
                 @zero_jitter
                 | api_timeout_error: true,
                   api_connection_error: false
               }),
               %Req.TransportError{reason: :timeout}
             ) == {:delay, 500}

      assert Retry.decide(
               request_for(%{@zero_jitter | api_timeout_error: true}),
               closed
             ) == {:delay, 500}
    end

    test "transport errors use backoff and honor the attempt number" do
      policy = %{@zero_jitter | max_retries: 3}

      assert Retry.decide(request_for(policy, 2), %Req.TransportError{reason: :closed}) ==
               {:delay, 2000}
    end

    test "retries are exhausted once :req_retry_count reaches max_retries" do
      policy = %{@zero_jitter | max_retries: 2}

      assert Retry.decide(request_for(policy, 1), response_with(503)) == {:delay, 1000}
      assert Retry.decide(request_for(policy, 2), response_with(503)) == false
      assert Retry.decide(request_for(policy, 3), response_with(503)) == false

      assert Retry.decide(request_for(policy, 2), %Req.TransportError{reason: :closed}) == false

      assert Retry.decide(request_for(%{policy | max_retries: 0}), response_with(503)) == false
    end
  end
end
