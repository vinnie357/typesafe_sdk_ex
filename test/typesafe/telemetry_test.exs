defmodule TypeSafe.TelemetryTest do
  use ExUnit.Case, async: true

  # Issue #13, slice 0: the JS SDK's logger (typesafe-sdk-js src/logging.ts and the
  # logger calls in src/client.ts, at commit 66880cc) as :telemetry events plus a
  # pure function that turns an event into the JS log line. The contract is the
  # operator decision comment on #13 (2026-09-30).
  #
  # Every client runs on StubAdapter with zero backoff and Retry-After 0, so
  # nothing here sleeps. Events fire in the calling process;
  # TypeSafe.TelemetryForwarder forwards only this test's own (and its Tasks'),
  # which is what keeps the module async-safe.
  #
  # `TypeSafe.Telemetry` does not exist until the implementation lands, so calls
  # into it go through `telemetry/2`: each test then fails at runtime on the
  # missing function or the missing event, and the file still compiles under
  # `--warnings-as-errors`.

  alias TypeSafe.Error
  alias TypeSafe.StubAdapter
  alias TypeSafe.TelemetryForwarder

  @ok_body ~s({"models":[]})
  @request %{state: "s", questions: %{q1: TypeSafe.noul("q")}}
  @secret "tsk_0123456789abcdef"
  @start [:typesafe, :attempt, :start]
  @stop [:typesafe, :attempt, :stop]
  @retry [:typesafe, :request, :retry]

  setup do
    id = TelemetryForwarder.attach(self())
    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  # The one seam into the not-yet-written module; see the header comment.
  defp telemetry(fun, args), do: apply(TypeSafe.Telemetry, fun, args)

  defp lines(events) do
    Enum.flat_map(events, fn {event, measurements, metadata} ->
      telemetry(:log_lines, [event, measurements, metadata])
    end)
  end

  # Zero backoff for every client in this file, so a retry never sleeps.
  defp client(stub, opts \\ []) do
    retry =
      Keyword.merge([backoff_initial_ms: 0, backoff_max_ms: 0], Keyword.get(opts, :retry, []))

    {:ok, client} = StubAdapter.client(stub, Keyword.put(opts, :retry, retry))
    client
  end

  # steps: {status, body} | {status, body, header_pairs} | {:error, reason}.
  # Past the end of the list: status 600, which is never retried, so an
  # over-eager retry loop shows up as a wrong event count.
  defp sequence(steps) do
    {:ok, agent} =
      start_supervised(Supervisor.child_spec({Agent, fn -> steps end}, id: make_ref()))

    fn request ->
      step =
        Agent.get_and_update(agent, fn
          [step | rest] -> {step, rest}
          [] -> {:exhausted, []}
        end)

      {request, step_result(step)}
    end
  end

  defp step_result({:error, reason}), do: Req.TransportError.exception(reason: reason)
  defp step_result({status, body}), do: step_result({status, body, []})

  defp step_result({status, body, headers}) do
    Req.Response.new(
      status: status,
      headers: [{"content-type", "application/json"} | headers],
      body: body
    )
  end

  defp step_result(:exhausted), do: step_result({600, ~s({"error":"exhausted"})})

  defp always(status, body) do
    fn request -> {request, step_result({status, body})} end
  end

  defp texts(events), do: Enum.map(lines(events), &elem(&1, 1))

  defp events, do: TelemetryForwarder.drain()

  defp list_models(client, opts \\ []), do: TypeSafe.list_models(client, opts)
  defp system_one(client), do: TypeSafe.system_one(client, @request, [])

  defp request_number(line) do
    [_line, number] = Regex.run(~r/^#(\d+) /, line)
    number
  end

  defp kinds(events), do: Enum.map(events, fn {event, _measurements, _metadata} -> event end)

  # ---- degenerate -----------------------------------------------------------

  test "list_models emits an attempt start and a paired stop" do
    client = client(StubAdapter.respond(200, @ok_body))

    assert {:ok, []} = list_models(client)

    assert [{@start, start_measurements, start}, {@stop, stop_measurements, stop}] = events()

    assert %{monotonic_time: monotonic, system_time: system} = start_measurements
    assert is_integer(monotonic)
    assert is_integer(system)

    assert %{request_number: n, method: :get, path: "/v1/models", attempt: 0, log_level: :warning} =
             start

    assert is_integer(n) and n > 0

    assert %{request_number: ^n, method: :get, path: "/v1/models", attempt: 0} = stop
    assert %{status: 200, error: nil, request_id: nil, log_level: :warning} = stop
    assert %{duration: duration} = stop_measurements
    assert is_integer(duration) and duration >= 0
  end

  test "at the default level (:warning) there are no log lines" do
    client = client(StubAdapter.respond(200, @ok_body))

    assert {:ok, []} = list_models(client)
    assert [_start, _stop] = events = events()
    assert lines(events) == []
  end

  test ":warning, :error and :off emit no lines on a 200, a 404 or a retried 429" do
    scenarios = [
      {"200", fn -> StubAdapter.respond(200, @ok_body) end},
      {"404", fn -> always(404, ~s({"message":"nope"})) end},
      {"429 then 200",
       fn ->
         sequence([{429, ~s({"error":"slow"}), [{"retry-after-ms", "0"}]}, {200, @ok_body}])
       end}
    ]

    for level <- [:off, :error, :warning], {name, stub} <- scenarios do
      client = client(stub.(), log_level: level)
      _result = list_models(client)
      events = events()

      refute events == [], "no events for #{name} at #{level}"
      assert Enum.all?(events, fn {_event, _m, metadata} -> metadata.log_level == level end)
      assert lines(events) == [], "lines for #{name} at #{level}"

      # E6: URL, headers and bodies are debug-only, at every other level too.
      for {_event, _measurements, metadata} <- events, key <- [:url, :headers, :body] do
        refute Map.has_key?(metadata, key), "#{key} leaked for #{name} at #{level}"
      end
    end
  end

  test "at :info the metadata carries no url, headers or bodies" do
    client = client(StubAdapter.respond(200, @ok_body), log_level: :info)

    assert {:ok, []} = list_models(client)
    assert [{@start, _, start}, {@stop, _, stop}] = events()

    assert %{log_level: :info} = start
    refute Map.has_key?(start, :headers)
    refute Map.has_key?(start, :body)
    refute Map.has_key?(start, :url)
    refute Map.has_key?(stop, :body)
  end

  # ---- happy path -----------------------------------------------------------

  test "at :info a 200 with a request id gives one summary line naming it" do
    headers = [{"content-type", "application/json"}, {"x-typesafe-request-id", "req_9"}]
    client = client(StubAdapter.respond(200, @ok_body, headers), log_level: :info)

    assert {:ok, []} = list_models(client)
    assert [{@start, _, _}, {@stop, _, %{request_id: "req_9"}}] = events = events()

    assert [{:info, line}] = lines(events)
    assert line =~ ~r{^#\d+ GET /v1/models <- 200 in \d+ms \(request req_9\)$}
  end

  test "at :info a 200 without a request id gives the summary line alone" do
    client = client(StubAdapter.respond(200, @ok_body), log_level: :info)

    assert {:ok, []} = list_models(client)

    assert [{:info, line}] = lines(events())
    assert line =~ ~r{^#\d+ GET /v1/models <- 200 in \d+ms$}
  end

  test "system_one at :info names POST /v1/systemone" do
    client = client(StubAdapter.respond(200, ~s({"answers":{}})), log_level: :info)

    assert {:ok, _answers} = system_one(client)

    assert [{:info, line}] = lines(events())
    assert line =~ ~r{^#\d+ POST /v1/systemone <- 200 in \d+ms$}
  end

  test "at :debug a GET logs the request, then the summary, then the body" do
    client =
      client(StubAdapter.respond(200, @ok_body),
        log_level: :debug,
        api_key: @secret,
        base_url: "https://x.test"
      )

    assert {:ok, []} = list_models(client)

    assert [{@start, _, start}, {@stop, _, stop}] = events = events()
    assert %{request_number: n, url: url, headers: headers, body: nil} = start
    assert url == "https://x.test/v1/models"

    # Req's shape: lowercase name => list of values, credentials already masked.
    assert %{"authorization" => ["Bearer ***cdef"]} = headers
    assert Enum.all?(headers, fn {name, values} -> is_binary(name) and is_list(values) end)
    assert %{body: %{"models" => []}} = stop

    # Ordering, as in JS client.ts:344,368,390: the request line, the summary
    # (logged before the body is parsed), then the body line.
    assert [{:debug, request_line}, {:info, summary}, {:debug, body_line}] = lines(events)

    assert request_line ==
             "##{n} GET /v1/models -> https://x.test/v1/models " <>
               inspect(%{headers: headers, body: nil})

    assert String.starts_with?(summary, "##{n} GET /v1/models <- 200 in ")
    assert summary =~ ~r/ in \d+ms$/
    assert body_line == "##{n} GET /v1/models <- body " <> inspect(%{"models" => []})
  end

  test "at :debug a POST reports the exact body it sent and its content-type" do
    client = client(StubAdapter.respond(200, ~s({"answers":{}})), log_level: :debug)

    assert {:ok, _answers} = system_one(client)
    assert_received {:sent, sent}

    assert [{@start, _, start} | _rest] = events()
    assert %{method: :post, path: "/v1/systemone", body: body, headers: headers} = start
    assert is_binary(body)
    assert body == IO.iodata_to_binary(sent.body)
    assert %{"content-type" => ["application/json"]} = headers
  end

  test "a 429 then a 200 at :info gives the attempt, retry and attempt lines in order" do
    stub = sequence([{429, ~s({"error":"slow"}), [{"retry-after-ms", "0"}]}, {200, @ok_body}])
    client = client(stub, log_level: :info)

    assert {:ok, []} = list_models(client)

    assert [{:info, first}, {:info, retry_line}, {:info, second}] = lines(events())
    assert first =~ ~r{^#\d+ GET /v1/models <- 429 in \d+ms$}
    assert retry_line =~ ~r{^#\d+ GET /v1/models retrying in 0ms \(retry 1/2\) after 429$}
    assert second =~ ~r{^#\d+ GET /v1/models <- 200 in \d+ms$}

    assert [_number] = Enum.uniq(Enum.map([first, retry_line, second], &request_number/1))
  end

  test "the retry event carries the delay, the failed attempt and the effective total" do
    stub = sequence([{429, ~s({"error":"slow"}), [{"retry-after-ms", "0"}]}, {200, @ok_body}])
    client = client(stub, log_level: :info)

    assert {:ok, []} = list_models(client)
    assert [_, _, _, _, _] = events = events()

    assert [@start, @stop, @retry, @start, @stop] = kinds(events)

    assert [{_, _, first_start}, _stop, {@retry, measurements, retry}, {_, _, second_start}, _] =
             events

    assert measurements == %{delay_ms: 0}
    assert %{retry: 1, max_retries: 2, reason: 429, attempt: 0} = retry
    assert %{attempt: 0, request_number: n} = first_start
    assert %{attempt: 1, request_number: ^n} = second_start
    assert %{request_number: ^n} = retry
  end

  test "a retried :debug call sends x-typesafe-retry-count on the second attempt (client.ts:365)" do
    stub = sequence([{429, ~s({"error":"slow"}), [{"retry-after-ms", "0"}]}, {200, @ok_body}])
    client = client(stub, log_level: :debug)

    assert {:ok, []} = list_models(client)

    starts = for {@start, _, metadata} <- events(), do: metadata
    assert [first, second] = starts
    refute Map.has_key?(first.headers, "x-typesafe-retry-count")
    assert %{"x-typesafe-retry-count" => ["1"]} = second.headers
  end

  test "a non-zero Retry-After is the delay in the event and in the line" do
    stub = sequence([{429, ~s({"error":"slow"}), [{"retry-after-ms", "1"}]}, {200, @ok_body}])
    client = client(stub, log_level: :info)

    assert {:ok, []} = list_models(client)

    events = events()

    assert [{@retry, %{delay_ms: 1} = measurements, _}] =
             Enum.filter(events, &match?({@retry, _, _}, &1))

    assert measurements == %{delay_ms: 1}

    assert Enum.any?(
             texts(events),
             &String.ends_with?(&1, "retrying in 1ms (retry 1/2) after 429")
           )
  end

  test "a per-call max_retries is the total in the retry line" do
    client = client(always(503, ~s({"error":"down"})), log_level: :info, retry: [max_retries: 5])

    assert {:error, %Error.InternalServer{}} = list_models(client, retry: [max_retries: 1])

    events = events()
    assert [_one_retry] = Enum.filter(events, fn {event, _m, _md} -> event == @retry end)

    assert Enum.any?(
             texts(events),
             &String.ends_with?(&1, "retrying in 0ms (retry 1/1) after 503")
           )
  end

  # ---- edge -----------------------------------------------------------------

  test "a 404 at :debug logs one summary and the error body, and still returns the error" do
    client = client(always(404, ~s({"message":"nope"})), log_level: :debug)

    assert {:error, %Error.NotFound{}} = list_models(client)

    assert [{:debug, request_line}, {:info, summary}, {:debug, error_line}] = lines(events())
    assert request_line =~ ~r{^#\d+ GET /v1/models -> }
    assert summary =~ ~r{^#\d+ GET /v1/models <- 404 in \d+ms$}

    assert error_line ==
             "##{request_number(summary)} GET /v1/models <- error body " <>
               inspect(%{"message" => "nope"})
  end

  test "at :debug the raw api key is in no event and no line" do
    scenarios = [
      fn -> {StubAdapter.respond(200, @ok_body), &list_models/1} end,
      fn ->
        steps = [{429, ~s({"error":"slow"}), [{"retry-after-ms", "0"}]}, {200, @ok_body}]
        {sequence(steps), &list_models/1}
      end,
      fn -> {StubAdapter.respond(200, ~s({"answers":{}})), &system_one/1} end
    ]

    all_events =
      Enum.flat_map(scenarios, fn scenario ->
        {stub, call} = scenario.()
        _result = call.(client(stub, log_level: :debug, api_key: @secret))
        events()
      end)

    assert length(all_events) >= 6
    all_lines = texts(all_events)
    refute all_lines == []
    assert Enum.all?(all_lines, &(not String.contains?(&1, @secret)))
    refute inspect(all_events, limit: :infinity, printable_limit: :infinity) =~ @secret
  end

  test "at :debug a default header whose value hides a space after a dashed word is fully masked" do
    client =
      client(StubAdapter.respond(200, @ok_body),
        log_level: :debug,
        default_headers: %{"x-api-key" => "sk-live-SUPERSECRETVALUE9 x"}
      )

    assert {:ok, []} = list_models(client)

    events = events()
    all_lines = texts(events)
    refute all_lines == []
    refute Enum.any?(all_lines, &String.contains?(&1, "SUPERSECRETVALUE9"))
    refute inspect(events, limit: :infinity, printable_limit: :infinity) =~ "SUPERSECRETVALUE9"
  end

  test "at :debug a digit-free dashed default header is fully masked too" do
    client =
      client(StubAdapter.respond(200, @ok_body),
        log_level: :debug,
        default_headers: %{"x-api-key" => "sk-live-SUPERSECRETVALUE x"}
      )

    assert {:ok, []} = list_models(client)

    events = events()
    all_lines = texts(events)
    refute all_lines == []
    refute Enum.any?(all_lines, &String.contains?(&1, "SUPERSECRETVALUE"))
    refute inspect(events, limit: :infinity, printable_limit: :infinity) =~ "SUPERSECRETVALUE"
  end

  # Red on 9b9a5d4: the letters-only word was logged as a "scheme".
  test "at :debug a letters-only default header value outside the allowlist is fully masked" do
    client =
      client(StubAdapter.respond(200, @ok_body),
        log_level: :debug,
        default_headers: %{"x-api-key" => "LETTERSONLYSECRETKEY x"}
      )

    assert {:ok, []} = list_models(client)

    events = events()
    all_lines = texts(events)
    refute all_lines == []
    refute Enum.any?(all_lines, &String.contains?(&1, "LETTERSONLYSECRETKEY"))
    refute inspect(events, limit: :infinity, printable_limit: :infinity) =~ "LETTERSONLYSECRETKEY"
  end

  # Red on fe4fa5f: a value split only by a non-breaking space kept its "abcd" tail.
  test "at :debug a default header split only by a non-breaking space is fully masked" do
    client =
      client(StubAdapter.respond(200, @ok_body),
        log_level: :debug,
        default_headers: %{"x-api-key" => "Custom#{<<0x00A0::utf8>>}abcd"}
      )

    assert {:ok, []} = list_models(client)

    events = events()
    assert [{@start, _, %{headers: headers}} | _rest] = events
    assert %{"x-api-key" => ["***"]} = headers

    all_lines = texts(events)
    refute all_lines == []
    refute Enum.any?(all_lines, &String.contains?(&1, "Custom"))
    refute Enum.any?(all_lines, &String.contains?(&1, ~s("***abcd")))
  end

  test "at :debug credentials in the base_url never reach the url metadata or the lines" do
    client =
      client(StubAdapter.respond(200, @ok_body),
        log_level: :debug,
        base_url: "https://user:hunter2pw@x.test"
      )

    assert {:ok, []} = list_models(client)

    assert [{@start, _, %{url: url}} | _rest] = events = events()
    assert url =~ "x.test/v1/models"
    refute url =~ "hunter2pw"
    refute url =~ "user:"

    all_lines = texts(events)
    refute all_lines == []
    refute Enum.any?(all_lines, &(&1 =~ "hunter2pw" or &1 =~ "user:"))
  end

  test "an empty x-typesafe-request-id header adds no suffix to the summary line" do
    headers = [{"content-type", "application/json"}, {"x-typesafe-request-id", ""}]
    client = client(StubAdapter.respond(200, @ok_body, headers), log_level: :info)

    assert {:ok, []} = list_models(client)

    assert [{:info, line}] = lines(events())
    assert line =~ ~r{^#\d+ GET /v1/models <- 200 in \d+ms$}
  end

  test "concurrent calls on one client get different request numbers" do
    client = client(StubAdapter.respond(200, @ok_body), log_level: :info)

    tasks = for _ <- 1..2, do: Task.async(fn -> list_models(client) end)
    assert [{:ok, []}, {:ok, []}] = Task.await_many(tasks)

    assert [{:info, first}, {:info, second}] = lines(events())
    refute request_number(first) == request_number(second)
  end

  test "log lines follow each client's own level" do
    info = client(StubAdapter.respond(200, @ok_body), log_level: :info)
    warning = client(StubAdapter.respond(200, @ok_body), log_level: :warning)

    assert {:ok, []} = list_models(info)
    assert [{@start, _, %{request_number: info_n}}, _stop] = info_events = events()
    assert {:ok, []} = list_models(warning)
    assert [{@start, _, %{request_number: warning_n}}, _stop] = warning_events = events()

    refute info_n == warning_n
    assert [{:info, line}] = lines(info_events ++ warning_events)
    assert request_number(line) == Integer.to_string(info_n)
  end

  test "a 200 that is not a models list still returns the existing error, with its lines" do
    client = client(StubAdapter.respond(200, ~s({"x":1})), log_level: :debug)

    assert {:error, %TypeSafe.Error{}} = list_models(client)

    assert [{:debug, _request}, {:info, summary}, {:debug, body_line}] = lines(events())
    assert summary =~ ~r{^#\d+ GET /v1/models <- 200 in \d+ms$}

    assert body_line ==
             "##{request_number(summary)} GET /v1/models <- body " <> inspect(%{"x" => 1})
  end

  test "a crashing handler never makes a call raise, and telemetry detaches it" do
    id = {__MODULE__, :crash, make_ref()}
    :ok = :telemetry.attach(id, @stop, &__MODULE__.crash/4, self())
    on_exit(fn -> :telemetry.detach(id) end)

    client = client(StubAdapter.respond(200, @ok_body))

    assert {:ok, []} = list_models(client)
    assert [_start, _stop] = events()

    refute Enum.any?(:telemetry.list_handlers(@stop), &(&1.id == id))
  end

  @doc false
  def crash(_event, _measurements, _metadata, test_pid) do
    case self() == test_pid do
      true -> raise "handler crash"
      false -> :ok
    end
  end

  # ---- log_lines/3, the pure seam ---------------------------------------------

  describe "log_lines/3" do
    @levels [:debug, :info, :warning, :error, :off]
    @rank %{debug: 0, info: 1, warning: 2, error: 3, off: 4}

    defp base(level),
      do: %{request_number: 7, method: :get, path: "/v1/models", attempt: 0, log_level: level}

    defp duration, do: %{duration: System.convert_time_unit(1234, :millisecond, :native)}

    defp stop(level, fields),
      do: Map.merge(Map.merge(base(level), %{status: nil, request_id: nil, error: nil}), fields)

    test "a response summary, with and without a request id" do
      assert [{:info, "#7 GET /v1/models <- 200 in 1234ms"}] =
               telemetry(:log_lines, [@stop, duration(), stop(:info, %{status: 200})])

      assert [{:info, "#7 GET /v1/models <- 200 in 1234ms (request r1)"}] =
               telemetry(:log_lines, [
                 @stop,
                 duration(),
                 stop(:info, %{status: 200, request_id: "r1"})
               ])
    end

    test "an empty request id adds no suffix" do
      assert [{:info, "#7 GET /v1/models <- 200 in 1234ms"}] =
               telemetry(:log_lines, [
                 @stop,
                 duration(),
                 stop(:info, %{status: 200, request_id: ""})
               ])
    end

    test "a timeout and a connection error" do
      timeout = %Error.Timeout{message: "Request timed out after 10ms.", timeout_ms: 10}
      connection = %Error.Connection{message: "Connection error: x", reason: :econnrefused}

      assert [{:info, "#7 GET /v1/models timed out after 1234ms"}] =
               telemetry(:log_lines, [@stop, duration(), stop(:info, %{error: timeout})])

      assert [{:info, "#7 GET /v1/models connection error after 1234ms " <> rest}] =
               telemetry(:log_lines, [@stop, duration(), stop(:info, %{error: connection})])

      assert rest == inspect(connection)
    end

    test "a retry" do
      metadata = Map.merge(base(:info), %{retry: 2, max_retries: 3, reason: 503})

      assert [{:info, "#7 GET /v1/models retrying in 250ms (retry 2/3) after 503"}] =
               telemetry(:log_lines, [@retry, %{delay_ms: 250}, metadata])
    end

    test "a line is kept when its level ranks at or above the client's; :off keeps nothing" do
      start_md = fn level ->
        Map.merge(base(level), %{url: "https://x.test/v1/models", headers: %{}, body: nil})
      end

      for client_level <- @levels do
        start = telemetry(:log_lines, [@start, %{}, start_md.(client_level)])
        summary = telemetry(:log_lines, [@stop, duration(), stop(client_level, %{status: 200})])

        assert Enum.map(start, &elem(&1, 0)) ==
                 keep(:debug, client_level),
               "debug line at #{client_level}"

        assert Enum.map(summary, &elem(&1, 0)) ==
                 keep(:info, client_level),
               "info line at #{client_level}"
      end
    end

    defp keep(line_level, client_level) do
      case @rank[line_level] >= @rank[client_level] do
        true -> [line_level]
        false -> []
      end
    end
  end

  # ---- redact_headers/1 (JS logging.ts:53-79) ---------------------------------

  describe "redact_headers/1" do
    defp redact(headers), do: telemetry(:redact_headers, [headers])

    test "masks credentials, keeps the scheme and the last four characters (logging.test.ts:192)" do
      input = %{
        "Authorization" => ["Bearer #{@secret}"],
        "x-api-key" => ["0123456789abcdef"],
        "Cookie" => ["session=abc"],
        "Accept" => ["application/json"]
      }

      assert redact(input) == %{
               "Authorization" => ["Bearer ***cdef"],
               "x-api-key" => ["***cdef"],
               "Cookie" => ["***"],
               "Accept" => ["application/json"]
             }
    end

    test "a short secret leaks no tail: the tail needs more than eight characters" do
      assert redact(%{"authorization" => ["Bearer abc"]}) == %{"authorization" => ["Bearer ***"]}

      assert redact(%{"authorization" => ["Bearer 12345678"]}) ==
               %{"authorization" => ["Bearer ***"]}

      assert redact(%{"authorization" => ["Bearer 123456789"]}) ==
               %{"authorization" => ["Bearer ***6789"]}
    end

    test "proxy-authorization and set-cookie" do
      assert redact(%{
               "proxy-authorization" => ["Basic dXNlcjpwYXNzd29yZA=="],
               "set-cookie" => ["id=1; Path=/"]
             }) == %{
               "proxy-authorization" => ["Basic ***ZA=="],
               "set-cookie" => ["***"]
             }
    end

    test "a value with no space is the secret itself" do
      assert redact(%{"x-api-key" => [@secret]}) == %{"x-api-key" => ["***cdef"]}
      assert redact(%{"authorization" => ["short"]}) == %{"authorization" => ["***"]}
    end

    test "runs of whitespace split once; a third token is ignored (JS split(/\\s+/, 2))" do
      assert redact(%{"authorization" => ["Bearer   #{@secret}"]}) ==
               %{"authorization" => ["Bearer ***cdef"]}

      # An allowed scheme keeps only its second token; a third token is ignored.
      assert redact(%{"authorization" => ["Bearer abcd efghijklmn"]}) ==
               %{"authorization" => ["Bearer ***"]}

      # "Scheme" is not an allowlisted scheme, so the whole value is masked, with no tail.
      assert redact(%{"authorization" => ["Scheme abcd efghijklmn"]}) ==
               %{"authorization" => ["***"]}

      assert redact(%{"authorization" => ["Bearer "]}) == %{"authorization" => ["Bearer ***"]}
    end

    # The first word is a scheme only when it is one of bearer, basic, token, digest
    # or negotiate (case-insensitive). Any other value that contains whitespace is
    # masked as exactly "***": a tail of the whole value would expose short secrets.
    test "a dashed first word is not a scheme: x-api-key is masked whole" do
      assert redact(%{"x-api-key" => ["sk-live-SUPERSECRETVALUE9 x"]}) ==
               %{"x-api-key" => ["***"]}
    end

    test "a digit-free dashed first word is not a scheme either: the dash alone rejects it" do
      assert redact(%{"x-api-key" => ["sk-live-SUPERSECRETVALUE x"]}) ==
               %{"x-api-key" => ["***"]}
    end

    test "a leading space leaves an empty first word, which is not a scheme" do
      assert redact(%{"authorization" => [" leading123456789"]}) ==
               %{"authorization" => ["***"]}
    end

    test "a first word with a digit is not a scheme: a trailing space does not hide it" do
      assert redact(%{"proxy-authorization" => ["SECRETPROXYTOKEN1 "]}) ==
               %{"proxy-authorization" => ["***"]}
    end

    test "a first word with digits and dashes is not a scheme: masked whole" do
      assert redact(%{"authorization" => ["tok3n-with-digits secret"]}) ==
               %{"authorization" => ["***"]}
    end

    test "a known scheme is kept" do
      assert redact(%{"authorization" => ["Token abcdefghijkl"]}) ==
               %{"authorization" => ["Token ***ijkl"]}
    end

    # Control (green on 9b9a5d4): the five allowlisted schemes keep their word as given.
    test "each allowlisted scheme is kept, in any case" do
      assert redact(%{
               "authorization" => ["Bearer abcdefghijkl"],
               "proxy-authorization" => ["basic abcdefghijkl"],
               "x-api-key" => ["TOKEN abcdefghijkl"]
             }) == %{
               "authorization" => ["Bearer ***ijkl"],
               "proxy-authorization" => ["basic ***ijkl"],
               "x-api-key" => ["TOKEN ***ijkl"]
             }

      assert redact(%{"authorization" => ["Digest abcdefghijkl"]}) ==
               %{"authorization" => ["Digest ***ijkl"]}

      assert redact(%{"authorization" => ["Negotiate abcdefghijkl"]}) ==
               %{"authorization" => ["Negotiate ***ijkl"]}
    end

    # Red on 9b9a5d4: a letters-only first word outside the allowlist was echoed.
    test "a letters-only first word outside the allowlist is masked whole" do
      assert redact(%{"x-api-key" => ["LETTERSONLYSECRETKEY x"]}) ==
               %{"x-api-key" => ["***"]}

      assert redact(%{"proxy-authorization" => ["PROXYLETTERSONLY "]}) ==
               %{"proxy-authorization" => ["***"]}
    end

    # Red on 9b9a5d4: the old code only looked for a space, so a tab or newline hid the
    # secret word behind a "scheme". Under the allowlist it is the letters-only case
    # again, here with other whitespace.
    test "a letters-only word followed by a tab or newline is masked whole" do
      assert redact(%{"authorization" => ["TABLETTERSECRET\tsk x"]}) ==
               %{"authorization" => ["***"]}

      assert redact(%{"authorization" => ["LETTERSNLSECRET\nx y"]}) ==
               %{"authorization" => ["***"]}
    end

    # Red on 9b9a5d4: a tab or newline alone separates the scheme, so the scheme is kept.
    test "an allowed scheme separated only by a tab or newline is kept" do
      assert redact(%{"authorization" => ["Bearer\tabcdefghijkl"]}) ==
               %{"authorization" => ["Bearer ***ijkl"]}

      assert redact(%{"authorization" => ["Basic\nabcdefghijkl"]}) ==
               %{"authorization" => ["Basic ***ijkl"]}
    end

    # Red on 9b9a5d4: a short secret after a non-scheme word got a tail or an echoed word.
    test "a non-scheme first word masks a short value with no tail" do
      assert redact(%{"authorization" => ["Custom abcd"]}) == %{"authorization" => ["***"]}
      assert redact(%{"authorization" => [" Bearer abc"]}) == %{"authorization" => ["***"]}
    end

    # Red on 9b9a5d4: a near-miss of an allowlisted word is not a scheme.
    test "a near-miss scheme word is masked whole" do
      assert redact(%{"authorization" => ["Bearerx abcdefghijkl"]}) ==
               %{"authorization" => ["***"]}

      assert redact(%{"authorization" => ["Tokens abcdefghijkl"]}) ==
               %{"authorization" => ["***"]}
    end

    # Unicode whitespace counts, as in JS \s. Red on fe4fa5f: its ASCII-only \s sent
    # these to the no-whitespace path, which kept a four-character tail (the secret).
    test "a non-scheme word separated only by Unicode whitespace is masked with no tail" do
      nbsp = <<0x00A0::utf8>>
      em_space = <<0x2003::utf8>>
      line_separator = <<0x2028::utf8>>

      assert redact(%{"authorization" => ["Custom#{nbsp}abcd"]}) ==
               %{"authorization" => ["***"]}

      assert redact(%{"authorization" => ["Custom#{em_space}abcd"]}) ==
               %{"authorization" => ["***"]}

      assert redact(%{"authorization" => ["Custom#{line_separator}abcd"]}) ==
               %{"authorization" => ["***"]}

      # Two more code points, so a hard-coded list of the ones above fails.
      assert redact(%{"authorization" => ["Custom#{<<0xFEFF::utf8>>}abcd"]}) ==
               %{"authorization" => ["***"]}

      assert redact(%{"authorization" => ["Custom#{<<0x2002::utf8>>}abcd"]}) ==
               %{"authorization" => ["***"]}
    end

    # Red on fe4fa5f: the scheme is not recognised, so the whole value keeps a tail.
    test "an allowed scheme separated only by Unicode whitespace is kept" do
      nbsp = <<0x00A0::utf8>>
      ideographic_space = <<0x3000::utf8>>

      assert redact(%{"authorization" => ["Bearer#{nbsp}abcdefghijkl"]}) ==
               %{"authorization" => ["Bearer ***ijkl"]}

      assert redact(%{"authorization" => ["Token#{ideographic_space}abcdefghijkl"]}) ==
               %{"authorization" => ["Token ***ijkl"]}

      assert redact(%{"authorization" => ["Bearer#{<<0xFEFF::utf8>>}abcdefghijkl"]}) ==
               %{"authorization" => ["Bearer ***ijkl"]}
    end

    # Green controls on fe4fa5f: invalid UTF-8 must never raise and keeps the ASCII
    # rule. A raise in the implementation fails these tests.
    test "invalid UTF-8 with an ASCII space follows the ASCII rule and does not raise" do
      assert redact(%{"authorization" => [<<"Bearer ", 0xFF, "abcdefghijkl">>]}) ==
               %{"authorization" => ["Bearer ***ijkl"]}

      assert redact(%{"authorization" => [<<"Custom ", 0xFF, "abcd">>]}) ==
               %{"authorization" => ["***"]}
    end

    test "invalid UTF-8 with no whitespace follows the no-whitespace rule and does not raise" do
      assert redact(%{"x-api-key" => [<<0xFF, "abcdefghijkl">>]}) ==
               %{"x-api-key" => ["***ijkl"]}
    end

    test "every value of a multi-value header is redacted" do
      assert redact(%{"authorization" => ["Bearer aaaaaaaaaa1111", "Bearer bbbbbbbbbb2222"]}) ==
               %{"authorization" => ["Bearer ***1111", "Bearer ***2222"]}
    end

    test "names are matched case-insensitively and come back as given" do
      assert redact(%{
               "AUTHORIZATION" => ["Bearer #{@secret}"],
               "X-Api-Key" => ["0123456789abcdef"],
               "SET-COOKIE" => ["a=b"],
               "X-Other" => ["kept"]
             }) == %{
               "AUTHORIZATION" => ["Bearer ***cdef"],
               "X-Api-Key" => ["***cdef"],
               "SET-COOKIE" => ["***"],
               "X-Other" => ["kept"]
             }
    end
  end

  # ---- transport errors -------------------------------------------------------

  test "a timeout at :info is one 'timed out' line, and the stop event reports it" do
    stub = fn request -> {request, Req.TransportError.exception(reason: :timeout)} end
    client = client(stub, log_level: :info, retry: [max_retries: 0])

    assert {:error, %Error.Timeout{}} = list_models(client)
    assert [{@start, _, _}, {@stop, _, stop}] = events = events()

    assert %{status: nil, error: %Error.Timeout{}} = stop
    assert [{:info, line}] = lines(events)
    assert line =~ ~r{^#\d+ GET /v1/models timed out after \d+ms$}
  end

  test "a refused connection at :info is one 'connection error' line carrying the error" do
    client =
      client(sequence([{:error, :econnrefused}]), log_level: :info, retry: [max_retries: 0])

    assert {:error, %Error.Connection{reason: :econnrefused}} = list_models(client)
    assert [{@start, _, _}, {@stop, _, stop}] = events = events()

    assert %{status: nil, error: %Error.Connection{reason: :econnrefused}} = stop
    assert [{:info, line}] = lines(events)
    assert line =~ ~r{^#\d+ GET /v1/models connection error after \d+ms }
    assert line =~ ":econnrefused"
  end

  test "retrying after a connection error names the error message as the reason" do
    client = client(sequence([{:error, :econnrefused}, {200, @ok_body}]), log_level: :info)

    assert {:ok, []} = list_models(client)

    assert [_, _, _, _, _] = events = events()
    assert [retry_line] = events |> texts() |> Enum.filter(&(&1 =~ "retrying in"))
    assert retry_line =~ ~r{^#\d+ GET /v1/models retrying in 0ms \(retry 1/2\) after }

    assert [{@retry, _, %{reason: %Error.Connection{reason: :econnrefused}}}] =
             Enum.filter(events, &match?({@retry, _, _}, &1))

    assert String.ends_with?(retry_line, "after Connection error: connection refused")
  end

  test "retrying after a timeout names the timeout message as the reason" do
    client =
      client(sequence([{:error, :timeout}, {200, @ok_body}]),
        log_level: :info,
        timeout: 1000,
        retry: [api_timeout_error: true]
      )

    assert {:ok, []} = list_models(client)

    events = events()
    assert [retry_line] = events |> texts() |> Enum.filter(&(&1 =~ "retrying in"))
    assert String.ends_with?(retry_line, "after Request timed out after 1000ms.")

    assert [{@retry, _, %{reason: %Error.Timeout{}}}] =
             Enum.filter(events, &match?({@retry, _, _}, &1))
  end

  # ---- pool exhaustion (same trigger as pool_test.exs, issue #12) -------------

  describe "pool exhaustion" do
    @pool_timeout_ms 50
    @holder_timeout_ms 5_000

    defp start_silent_server do
      test_pid = self()

      {:ok, _pid} =
        start_supervised(
          Supervisor.child_spec(
            {Task,
             fn ->
               {:ok, listen} =
                 :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

               {:ok, port} = :inet.port(listen)
               send(test_pid, {:listening, port})
               accept_loop(listen, test_pid)
             end},
            id: make_ref()
          )
        )

      assert_receive {:listening, port}, 5_000
      port
    end

    defp accept_loop(listen, test_pid) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          handler =
            spawn_link(fn ->
              receive do
                :never -> :ok
              end
            end)

          :ok = :gen_tcp.controlling_process(socket, handler)
          send(test_pid, :accepted)
          accept_loop(listen, test_pid)

        {:error, _closed} ->
          :ok
      end
    end

    defp pool_client(port, finch_options, timeout) do
      {:ok, client} =
        TypeSafe.new(
          api_key: "k",
          base_url: "http://127.0.0.1:#{port}",
          timeout: timeout,
          log_level: :info,
          req_options: [finch: finch_options],
          get_env: fn _name -> nil end
        )

      client
    end

    test "start and stop stay paired, stop reports the pool_timeout, and the result is unchanged" do
      port = start_silent_server()
      name = :"typesafe_telemetry_pool_#{System.unique_integer([:positive])}"
      {:ok, _pid} = start_supervised({Finch, name: name, pools: %{default: [size: 1, count: 1]}})

      holder_client = pool_client(port, [name: name], @holder_timeout_ms)
      holder = Task.async(fn -> TypeSafe.list_models(holder_client, []) end)
      assert_receive :accepted, 5_000

      waiter = pool_client(port, [name: name, pool_timeout: @pool_timeout_ms], @holder_timeout_ms)
      quick = [max_retries: 3, backoff_initial_ms: 1, backoff_max_ms: 1, backoff_jitter: 0]

      assert {:error, %Error.Connection{reason: :pool_timeout}} =
               TypeSafe.list_models(waiter, retry: quick)

      # The holder's own start event is in the mailbox too: keep the waiter's only.
      all = events()
      assert %{request_number: n} = all |> Enum.find_value(&pool_timeout_stop/1)
      mine = Enum.filter(all, fn {_event, _m, md} -> md.request_number == n end)

      assert [@start, @stop] = kinds(mine)
      assert [{_, _, start}, {_, _, stop}] = mine
      assert %{attempt: 0} = start
      assert %{status: nil, error: %Error.Connection{reason: :pool_timeout}} = stop

      assert Enum.any?(texts(mine), &(&1 =~ ~r{connection error after \d+ms}))

      Task.shutdown(holder, :brutal_kill)
    end

    defp pool_timeout_stop({@stop, _m, %{error: %Error.Connection{reason: :pool_timeout}} = md}),
      do: md

    defp pool_timeout_stop(_event), do: nil
  end
end
