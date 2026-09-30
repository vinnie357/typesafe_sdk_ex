defmodule TypeSafe.ReliabilityTest do
  use ExUnit.Case, async: true

  # docs/spec.md §11 S3b #27-46 (stubbed, end to end through real Req retries).
  #
  # Every client here is built through retry_client/2, which forces zero
  # backoff, so no test sleeps (a missed one would sleep 375-1500ms, §11 S3).
  # Retry-After tests send `retry-after-ms: 0`. Stateful sequences come from an
  # Agent started with start_supervised/1; requests reach the test as
  # `{:sent, request}` messages, drained by drain_sent/0.

  alias TypeSafe.Error
  alias TypeSafe.RetryPolicy
  alias TypeSafe.StubAdapter

  @ok_body ~s({"models":[]})
  @request %{state: "s", questions: %{q1: TypeSafe.noul("q")}}

  # The single funnel for every stubbed client in this file (§11 S3 convention).
  defp retry_client(stub, opts) do
    retry =
      Keyword.merge([backoff_initial_ms: 0, backoff_max_ms: 0], Keyword.get(opts, :retry, []))

    StubAdapter.client(stub, Keyword.put(opts, :retry, retry))
  end

  # steps: {status, body} | {status, body, header_pairs} | {:error, reason}.
  # A request past the end of the list gets status 600 ("exhausted"), which is
  # never retried, so an over-eager retry loop shows up as a wrong count.
  defp sequence(steps) do
    {:ok, agent} =
      start_supervised(Supervisor.child_spec({Agent, fn -> steps end}, id: make_ref()))

    test_pid = self()

    fn request ->
      send(test_pid, {:sent, request})

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

  defp drain_sent(acc \\ []) do
    receive do
      {:sent, request} -> drain_sent([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp retry_count_header(request), do: Req.Request.get_header(request, "x-typesafe-retry-count")

  defp call(:list_models, client, opts), do: TypeSafe.list_models(client, opts)
  defp call(:system_one, client, opts), do: TypeSafe.system_one(client, @request, opts)

  defp error_body(text), do: ~s({"error":"#{text}"})

  # §11 S3b #27
  test "200 on the first attempt sends one request with no retry-count header" do
    for function <- [:list_models, :system_one] do
      {:ok, client} = retry_client(sequence([{200, @ok_body}, {200, @ok_body}]), [])

      assert {:ok, _data} = call(function, client, [])
      assert [request] = drain_sent()
      assert retry_count_header(request) == []
    end
  end

  # §11 S3b #28 (reliability.test.ts:51-73)
  test "429 with retry-after-ms 0 then 200 sends 2 requests" do
    stub = sequence([{429, error_body("slow"), [{"retry-after-ms", "0"}]}, {200, @ok_body}])
    {:ok, client} = retry_client(stub, [])

    assert {:ok, []} = TypeSafe.list_models(client)
    assert length(drain_sent()) == 2
  end

  # §11 S3b #29 (reliability.test.ts:75-92)
  test "503, 503, 200 sends 3 requests" do
    stub = sequence([{503, error_body("a")}, {503, error_body("b")}, {200, @ok_body}])
    {:ok, client} = retry_client(stub, [])

    assert {:ok, []} = TypeSafe.list_models(client)
    assert length(drain_sent()) == 3
  end

  # §11 S3b #30 (reliability.test.ts:94-99): the LAST error is returned.
  test "gives up after max_retries and returns the last error" do
    stub =
      sequence([
        {503, error_body("first")},
        {503, error_body("second")},
        {503, error_body("third")},
        {503, error_body("fourth")},
        {503, error_body("fifth")}
      ])

    {:ok, client} = retry_client(stub, retry: [max_retries: 3])

    assert {:error, %Error.InternalServer{status: 503, body: %{"error" => "fourth"}}} =
             TypeSafe.list_models(client)

    assert length(drain_sent()) == 4
  end

  # §11 S3b #31 (reliability.test.ts:101-106)
  test "400 is not retried" do
    {:ok, client} =
      retry_client(sequence([{400, error_body("bad")}, {200, @ok_body}]), [])

    assert {:error, %Error.BadRequest{status: 400}} = TypeSafe.list_models(client)
    assert length(drain_sent()) == 1
  end

  # §11 S3b #32 (release-regressions.test.ts:15-58)
  test "POST system_one retries a 503 and resends the same body" do
    stub = sequence([{503, error_body("busy")}, {200, @ok_body}])
    {:ok, client} = retry_client(stub, [])

    assert {:ok, %{"models" => []}} = TypeSafe.system_one(client, @request)
    assert [first, second] = drain_sent()
    assert {first.method, second.method} == {:post, :post}

    {:ok, first_body} = JSON.decode(IO.iodata_to_binary(first.body))
    {:ok, second_body} = JSON.decode(IO.iodata_to_binary(second.body))
    assert first_body == second_body
    assert first_body["state"] == "s"
  end

  # §11 S3b #33 (reliability.test.ts:108-117)
  test ":closed then 200 sends 2 requests" do
    {:ok, client} = retry_client(sequence([{:error, :closed}, {200, @ok_body}]), [])

    assert {:ok, []} = TypeSafe.list_models(client)
    assert length(drain_sent()) == 2
  end

  # §11 S3b #34 (reliability.test.ts:144-151)
  test "per-call max_retries 0 overrides client max_retries 5" do
    for function <- [:list_models, :system_one] do
      stub = sequence([{503, error_body("busy")}, {200, @ok_body}])
      {:ok, client} = retry_client(stub, retry: [max_retries: 5])

      assert {:error, %Error.InternalServer{}} =
               call(function, client, retry: [max_retries: 0])

      assert length(drain_sent()) == 1
    end
  end

  # §11 S3b #35 (reliability.test.ts:383-400)
  test "per-call retry merges field by field and leaves client.retry unchanged" do
    for function <- [:list_models, :system_one] do
      # The client opts in to timeout retries; the call only raises max_retries.
      stub = sequence([{:error, :timeout}, {:error, :timeout}, {200, @ok_body}])
      {:ok, client} = retry_client(stub, retry: [max_retries: 1, api_timeout_error: true])
      before = client.retry

      assert {:ok, _data} = call(function, client, retry: [max_retries: 2])
      assert length(drain_sent()) == 3
      assert client.retry == before
      assert client.retry.max_retries == 1

      # The call flips only api_timeout_error; the client's max_retries stays.
      stub = sequence([{:error, :timeout}, {200, @ok_body}])
      {:ok, client} = retry_client(stub, retry: [max_retries: 1, api_timeout_error: true])

      assert {:error, %Error.Timeout{}} =
               call(function, client, retry: [api_timeout_error: false])

      assert length(drain_sent()) == 1
    end
  end

  # §11 S3b #36 (reliability.test.ts:153-166)
  test "X-TypeSafe-Retry-Count is absent, then 1, then 2" do
    for function <- [:list_models, :system_one] do
      stub = sequence([{503, error_body("a")}, {503, error_body("b")}, {200, @ok_body}])
      {:ok, client} = retry_client(stub, [])

      assert {:ok, _data} = call(function, client, [])
      assert Enum.map(drain_sent(), &retry_count_header/1) == [[], ["1"], ["2"]]
    end
  end

  # §11 S3b #37 (release-regressions.test.ts:15-58)
  test "a caller's retry-count header is removed on every attempt, protected headers intact" do
    for function <- [:list_models, :system_one] do
      stub = sequence([{503, error_body("a")}, {503, error_body("b")}, {200, @ok_body}])

      {:ok, client} =
        retry_client(stub, default_headers: %{"X-TypeSafe-Retry-Count" => "99"})

      assert {:ok, _data} =
               call(function, client, headers: %{"x-typesafe-retry-count" => "77"})

      requests = drain_sent()
      assert Enum.map(requests, &retry_count_header/1) == [[], ["1"], ["2"]]

      for request <- requests do
        assert Req.Request.get_header(request, "authorization") == ["Bearer k"]
        assert Req.Request.get_header(request, "accept") == ["application/json"]

        assert [<<"typesafe-sdk-ex/", _version::binary>>] =
                 Req.Request.get_header(request, "user-agent")
      end
    end
  end

  # §11 S3b #38 (reliability.test.ts:260-278)
  test "only listed statuses are retried" do
    stub = sequence([{409, error_body("a")}, {409, error_body("b")}, {409, error_body("c")}])
    {:ok, client} = retry_client(stub, retry: [http_statuses: [409]])

    assert {:error, %Error.API{status: 409}} = TypeSafe.list_models(client)
    assert length(drain_sent()) == 3

    stub = sequence([{503, error_body("a")}, {200, @ok_body}])
    {:ok, client} = retry_client(stub, retry: [http_statuses: []])

    assert {:error, %Error.InternalServer{status: 503}} = TypeSafe.list_models(client)
    assert length(drain_sent()) == 1
  end

  # §11 S3b #39 (reliability.test.ts:280-308)
  test "api_connection_error false stops :closed retries; timeouts follow their own flag" do
    stub = sequence([{:error, :closed}, {200, @ok_body}])
    {:ok, client} = retry_client(stub, retry: [api_connection_error: false])

    assert {:error, %Error.Connection{reason: :closed}} = TypeSafe.list_models(client)
    assert length(drain_sent()) == 1

    stub = sequence([{:error, :timeout}, {:error, :timeout}, {200, @ok_body}])

    {:ok, client} =
      retry_client(stub,
        retry: [api_connection_error: false, api_timeout_error: true, max_retries: 1]
      )

    assert {:error, %Error.Timeout{}} = TypeSafe.list_models(client)
    assert length(drain_sent()) == 2
  end

  # §11 S3b #40 (reliability.test.ts:310-338); q20: the default case is
  # Elixir-only, JS retries timeouts by default.
  test "timeout retries are opt-in" do
    for function <- [:list_models, :system_one] do
      stub = sequence([{:error, :timeout}, {200, @ok_body}])
      {:ok, client} = retry_client(stub, [])

      assert {:error, %Error.Timeout{}} = call(function, client, [])
      assert length(drain_sent()) == 1

      stub = sequence([{:error, :timeout}, {200, @ok_body}])
      {:ok, client} = retry_client(stub, retry: [api_timeout_error: true])

      assert {:ok, _data} = call(function, client, [])
      assert length(drain_sent()) == 2
    end

    stub = sequence([{:error, :closed}, {:error, :closed}, {200, @ok_body}])
    {:ok, client} = retry_client(stub, retry: [max_retries: 1])

    assert {:error, %Error.Connection{reason: :closed}} = TypeSafe.list_models(client)
    assert length(drain_sent()) == 2
  end

  # §11 S3b #41 (q20): a timed-out POST may already have been processed and billed.
  test "POST system_one timeout is not retried by default, and is with api_timeout_error: true" do
    stub = sequence([{:error, :timeout}, {200, @ok_body}])
    {:ok, client} = retry_client(stub, [])

    assert {:error, %Error.Timeout{}} = TypeSafe.system_one(client, @request)
    assert [request] = drain_sent()
    assert request.method == :post

    stub = sequence([{:error, :timeout}, {200, @ok_body}])
    {:ok, client} = retry_client(stub, retry: [api_timeout_error: true])

    assert {:ok, _data} = TypeSafe.system_one(client, @request)
    assert length(drain_sent()) == 2
  end

  # §11 S3b #42 (reliability.test.ts:362-381). retry-after-ms is "1" rather
  # than "0" so a wrongly honored header would still cost only 1ms.
  test "respect_retry_after false with zero backoff still retries" do
    stub = sequence([{429, error_body("slow"), [{"retry-after-ms", "1"}]}, {200, @ok_body}])
    {:ok, client} = retry_client(stub, retry: [respect_retry_after: false])

    assert {:ok, []} = TypeSafe.list_models(client)
    assert length(drain_sent()) == 2
  end

  # §11 S3b #43 (reliability.test.ts:195-199)
  test "new/1 with retry stores the resolved policy struct" do
    assert {:ok, client} =
             TypeSafe.new(
               api_key: "k",
               get_env: fn _name -> nil end,
               retry: [max_retries: 5, api_timeout_error: true]
             )

    assert %RetryPolicy{} = client.retry
    assert client.retry == %{%RetryPolicy{} | max_retries: 5, api_timeout_error: true}

    assert {:ok, default} =
             TypeSafe.new(api_key: "k", get_env: fn _name -> nil end, retry: [])

    assert default.retry == %RetryPolicy{}
  end

  # §11 S3b #44 (reliability.test.ts:168-180, 414-421)
  test "an invalid retry is rejected at new/1 with the field named" do
    for {retry, needle} <- [
          {[max_retries: -1], "retry.max_retries"},
          {[max_retries: 1.5], "retry.max_retries"},
          {[backoff_jitter: 1.5], "retry.backoff_jitter"},
          {[http_statuses: [503, 42]], "retry.http_statuses"},
          {[api_timeout_error: "yes"], "retry.api_timeout_error"},
          {[bogus: 1], "bogus"},
          {nil, "retry"}
        ] do
      assert {:error, %Error{message: message}} =
               TypeSafe.new(api_key: "k", get_env: fn _name -> nil end, retry: retry)

      assert message =~ needle
    end
  end

  test "an invalid retry is rejected per call with the field named and zero requests" do
    for function <- [:list_models, :system_one],
        {retry, needle} <- [
          {[max_retries: -1], "retry.max_retries"},
          {[backoff_initial_ms: -1], "retry.backoff_initial_ms"},
          {[http_statuses: [500.5]], "retry.http_statuses"},
          {[bogus: 1], "bogus"},
          {nil, "retry"}
        ] do
      {:ok, client} = retry_client(sequence([{200, @ok_body}]), [])

      assert {:error, %Error{message: message}} = call(function, client, retry: retry)
      assert message =~ needle
      assert drain_sent() == []
    end
  end

  # §11 S3b #45 (§4; req@0.7.4 steps.ex:1748-1753): the retry wiring owns these.
  test "req_options retry_delay, max_retries, and retry_log_level are each rejected by name" do
    for {key, value} <- [retry_delay: 1, max_retries: 1, retry_log_level: false] do
      assert {:error, %Error{message: message}} =
               TypeSafe.new(
                 api_key: "k",
                 get_env: fn _name -> nil end,
                 req_options: [{key, value}]
               )

      assert message =~ Atom.to_string(key)
    end
  end

  # §11 S3b #46, §10 S3b AC(7): the per-call Req wiring the adapter can see.
  test "Req retry logging is off and the retry wiring reaches every attempt" do
    for function <- [:list_models, :system_one] do
      stub = sequence([{503, error_body("a")}, {200, @ok_body}])
      {:ok, client} = retry_client(stub, retry: [max_retries: 4])

      assert {:ok, _data} = call(function, client, [])
      assert [first, second] = drain_sent()

      for request <- [first, second] do
        assert request.options[:retry_log_level] == false
        assert is_function(request.options[:retry], 2)
        assert request.options[:max_retries] == 4
        assert request.private[:typesafe_retry_policy] == client.retry
      end
    end
  end

  test "a per-call retry override reaches the Req wiring as the effective policy" do
    stub = sequence([{200, @ok_body}])
    {:ok, client} = retry_client(stub, retry: [max_retries: 4])

    assert {:ok, []} = TypeSafe.list_models(client, retry: [max_retries: 0])
    assert [request] = drain_sent()
    assert request.options[:max_retries] == 0
    assert request.private[:typesafe_retry_policy].max_retries == 0
    assert request.private[:typesafe_retry_policy].backoff_initial_ms == 0
  end
end
