defmodule TypeSafe.TimeoutTest do
  use ExUnit.Case, async: true

  # docs/spec.md §11 S3c #47-56 (§5 "Timeout", §4 timeout and retry rows).
  #
  # Stubbed tests build clients through stub_client/2, which defaults to
  # `retry: [max_retries: 0]`: nothing here retries unless a test opts in, and
  # then with zero backoff, so no stubbed test sleeps. Requests reach the test
  # as `{:sent, request}` messages, drained by drain_sent/0.
  #
  # Test #52 is the one real-socket test: a loopback :gen_tcp server on a port
  # the OS picks (port 0), the boundary this SDK cannot stub away.

  alias TypeSafe.Error
  alias TypeSafe.StubAdapter

  @ok_body ~s({"models":[]})
  @request %{state: "s", questions: %{q1: TypeSafe.noul("q")}}
  @functions [:list_models, :system_one]
  @invalid_timeouts [0, -5, 1.5, nil, "x"]
  @no_wait [backoff_initial_ms: 0, backoff_max_ms: 0]

  defp stub_client(stub, opts) do
    StubAdapter.client(stub, Keyword.put_new(opts, :retry, max_retries: 0))
  end

  defp call(:list_models, client, opts), do: TypeSafe.list_models(client, opts)
  defp call(:system_one, client, opts), do: TypeSafe.system_one(client, @request, opts)

  defp drain_sent(acc \\ []) do
    receive do
      {:sent, request} -> drain_sent([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp receive_timeouts, do: Enum.map(drain_sent(), & &1.options[:receive_timeout])

  defp timeout_stub do
    test_pid = self()

    fn request ->
      send(test_pid, {:sent, request})
      {request, Req.TransportError.exception(reason: :timeout)}
    end
  end

  # steps: :timeout | {status, body}. Past the end of the list: status 600,
  # which is never retried, so an over-eager retry loop shows up as a wrong count.
  defp sequence(steps) do
    {:ok, agent} =
      start_supervised(Supervisor.child_spec({Agent, fn -> steps end}, id: make_ref()))

    test_pid = self()

    fn request ->
      send(test_pid, {:sent, request})

      step =
        Agent.get_and_update(agent, fn
          [step | rest] -> {step, rest}
          [] -> {{600, ~s({"error":"exhausted"})}, []}
        end)

      {request, step_result(step)}
    end
  end

  defp step_result(:timeout), do: Req.TransportError.exception(reason: :timeout)

  defp step_result({status, body}) do
    Req.Response.new(
      status: status,
      headers: [{"content-type", "application/json"}],
      body: body
    )
  end

  defp new_client(opts) do
    TypeSafe.new([api_key: "k", get_env: fn _name -> nil end] ++ opts)
  end

  # §11 S3c #47 (reliability.test.ts:460-474)
  test "new(timeout: 250) sets client.timeout and reaches receive_timeout on both functions" do
    for function <- @functions do
      {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), timeout: 250)

      assert client.timeout == 250
      assert {:ok, _data} = call(function, client, [])
      assert receive_timeouts() == [250]
    end
  end

  # §11 S3c #48 (reliability.test.ts:493-505)
  test "a per-call timeout overrides the client's and leaves the client unchanged" do
    for function <- @functions do
      {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), timeout: 250)

      assert {:ok, _data} = call(function, client, timeout: 75)
      assert receive_timeouts() == [75]

      assert client.timeout == 250
      assert {:ok, _data} = call(function, client, [])
      assert receive_timeouts() == [250]
    end
  end

  # §11 S3c #48, §5: with no `timeout:` anywhere the default still applies.
  test "a per-call timeout applies on a client built with the default timeout" do
    for function <- @functions do
      {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), [])

      assert {:ok, _data} = call(function, client, timeout: 75)
      assert receive_timeouts() == [75]
    end
  end

  # §11 S3c #49 (reliability.test.ts:445-458)
  test "Timeout reports the effective per-call value" do
    for function <- @functions do
      {:ok, client} = stub_client(timeout_stub(), timeout: 30)

      assert {:error, %Error.Timeout{timeout_ms: 50, message: "Request timed out after 50ms."}} =
               call(function, client, timeout: 50)

      assert receive_timeouts() == [50]
    end
  end

  # §11 S3c #49, §5: without a per-call value the client's value is reported.
  test "Timeout reports the client's timeout when the call gives none" do
    for function <- @functions do
      {:ok, client} = stub_client(timeout_stub(), timeout: 30)

      assert {:error, %Error.Timeout{timeout_ms: 30, message: "Request timed out after 30ms."}} =
               call(function, client, [])
    end
  end

  # §11 S3c #50 (reliability.test.ts:476-491): every attempt gets the same timeout.
  test "the same per-attempt timeout is sent on every retry" do
    for function <- @functions do
      retry = [api_timeout_error: true] ++ @no_wait
      stub = sequence([:timeout, :timeout, {200, @ok_body}])
      {:ok, client} = stub_client(stub, timeout: 40, retry: retry)

      assert {:ok, _data} = call(function, client, [])
      assert receive_timeouts() == [40, 40, 40]
    end
  end

  test "a per-call timeout is sent on every retry, and the client's is not" do
    for function <- @functions do
      retry = [api_timeout_error: true] ++ @no_wait
      stub = sequence([:timeout, {200, @ok_body}])
      {:ok, client} = stub_client(stub, timeout: 40, retry: retry)

      assert {:ok, _data} = call(function, client, timeout: 60)
      assert receive_timeouts() == [60, 60]
    end
  end

  # §11 S3c #51 (reliability.test.ts:524-534)
  test "an invalid timeout is rejected at new/1, naming the option" do
    for bad <- @invalid_timeouts do
      assert {:error, %Error{message: message}} = new_client(timeout: bad)
      assert message == "timeout must be a positive integer, got #{inspect(bad)}"
    end
  end

  # §11 S3c #51: rejected before any request is sent.
  test "an invalid per-call timeout is rejected with zero requests" do
    for function <- @functions, bad <- @invalid_timeouts do
      {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), [])

      assert {:error, %Error{message: message}} = call(function, client, timeout: bad)
      assert message == "timeout must be a positive integer, got #{inspect(bad)}"
      assert drain_sent() == []
    end
  end

  # §11 S3c #53: 1 is the smallest valid value; 0 and -1 are the nearest invalid ones.
  test "timeout: 1 is accepted at both levels, and 0 and -1 are rejected" do
    for function <- @functions do
      {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), timeout: 1)
      assert {:ok, _data} = call(function, client, [])
      assert receive_timeouts() == [1]

      {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), [])
      assert {:ok, _data} = call(function, client, timeout: 1)
      assert receive_timeouts() == [1]
    end

    for bad <- [0, -1] do
      assert {:error, %Error{message: message}} = new_client(timeout: bad)
      assert message == "timeout must be a positive integer, got #{bad}"
    end
  end

  # §11 S3c #54, Gate 4 review of S3b N1. These pin messages that already
  # exist, so they are green when written; they stop the docs drifting again.
  test "retry: nil and an unknown retry key are rejected with their exact messages" do
    for {retry, expected} <- [
          {nil, "retry must be a keyword list, got nil"},
          {[bogus: 1], "retry has unknown option(s): bogus"}
        ] do
      assert {:error, %Error{message: ^expected}} = new_client(retry: retry)

      for function <- @functions do
        {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), [])

        assert {:error, %Error{message: ^expected}} = call(function, client, retry: retry)
        assert drain_sent() == []
      end
    end
  end

  # §11 S3c #55, Gate 4 review of S3b N2: today this reports "unknown option(s)".
  test "a duplicated retry key is rejected by name, not as an unknown option" do
    for {retry, key} <- [
          {[max_retries: 1, max_retries: 2], "max_retries"},
          {[api_timeout_error: true, backoff_jitter: 0.1, backoff_jitter: 0.2], "backoff_jitter"}
        ] do
      expected = "retry.#{key} given more than once"

      assert {:error, %Error{message: ^expected}} = new_client(retry: retry)

      for function <- @functions do
        {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), [])

        assert {:error, %Error{message: ^expected}} = call(function, client, retry: retry)
        assert drain_sent() == []
      end
    end
  end

  # §11 S3c #56, Gate 4 review of S3b N4. The behavior already exists (the
  # README claims it), so these are green when written and guard the claim.
  test "floats are rejected in the three millisecond retry fields" do
    for {field, value} <- [backoff_initial_ms: 1.5, backoff_max_ms: 1.0, max_retry_after_ms: 1.5] do
      expected = "retry.#{field} must be a non-negative integer, got #{inspect(value)}"

      assert {:error, %Error{message: ^expected}} = new_client(retry: [{field, value}])

      for function <- @functions do
        {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), [])

        assert {:error, %Error{message: ^expected}} =
                 call(function, client, retry: [{field, value}])

        assert drain_sent() == []
      end
    end
  end

  describe "real socket (§11 S3c #52)" do
    # A long-lived acceptor process owns the listener and accepts in a loop,
    # one linked process per connection. A single-accept server produced a
    # false `:closed` in the PR #3 review, so the shape matters. The first
    # request seen is answered after `delay_ms`; every later one at once.
    defp start_server(delay_ms) do
      test_pid = self()
      requests = :atomics.new(1, [])

      {:ok, _pid} =
        start_supervised(
          Supervisor.child_spec(
            {Task,
             fn ->
               {:ok, listen} =
                 :gen_tcp.listen(0, [
                   :binary,
                   ip: {127, 0, 0, 1},
                   active: false,
                   reuseaddr: true
                 ])

               {:ok, port} = :inet.port(listen)
               send(test_pid, {:listening, listen, port})
               accept_loop(listen, requests, delay_ms)
             end},
            id: make_ref()
          )
        )

      assert_receive {:listening, listen, port}, 5_000
      on_exit(fn -> _ = :gen_tcp.close(listen) end)
      port
    end

    defp accept_loop(listen, requests, delay_ms) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          handler = spawn_link(fn -> receive_go_then_serve(socket, requests, delay_ms) end)
          :ok = :gen_tcp.controlling_process(socket, handler)
          send(handler, :go)
          accept_loop(listen, requests, delay_ms)

        {:error, _closed} ->
          :ok
      end
    end

    defp receive_go_then_serve(socket, requests, delay_ms) do
      receive do
        :go -> serve(socket, "", requests, delay_ms)
      end
    end

    defp serve(socket, buffer, requests, delay_ms) do
      case String.split(buffer, "\r\n\r\n", parts: 2) do
        [_request, rest] ->
          respond(socket, requests, delay_ms)
          serve(socket, rest, requests, delay_ms)

        [_incomplete] ->
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, data} -> serve(socket, buffer <> data, requests, delay_ms)
            {:error, _closed_or_timeout} -> :ok
          end
      end
    end

    defp respond(socket, requests, delay_ms) do
      if :atomics.add_get(requests, 1, 1) == 1, do: Process.sleep(delay_ms)

      _ =
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
          Integer.to_string(byte_size(@ok_body)),
          "\r\n\r\n",
          @ok_body
        ])

      :ok
    end

    defp clean?({:ok, _data}), do: true

    defp clean?({:error, %module{}}),
      do: module |> Module.split() |> Enum.take(2) == ["TypeSafe", "Error"]

    defp clean?(_other), do: false

    # Regression for the Mint 1.11 / Finch 0.23.0 bug found in PR #3: a receive
    # timeout left the request in flight on a pooled connection, and an
    # immediate retry was pipelined behind it and raised on the stale
    # response. The second call carries a long per-call timeout so it is still
    # waiting when the delayed first response lands.
    test "a call after a receive timeout on the same client never raises" do
      port = start_server(150)

      {:ok, client} =
        new_client(
          base_url: "http://127.0.0.1:#{port}",
          timeout: 50,
          retry: [max_retries: 0]
        )

      assert {:error, %Error.Timeout{timeout_ms: 50}} = TypeSafe.list_models(client)

      result = TypeSafe.list_models(client, timeout: 2_000)

      assert clean?(result), "expected {:ok, _} or a TypeSafe.Error, got: #{inspect(result)}"
    end
  end

  # §11 S3c #57 (Gate 4 B2, PR #6). Req merges `finch:` request options over the
  # top-level ones (req/finch.ex:237-240), so each of these would let
  # `Timeout{timeout_ms}` report a number that did not fire.
  test "req_options cannot override the timeout through request_timeout" do
    assert {:error, %Error{message: message}} = new_client(req_options: [request_timeout: 5])

    assert message ==
             "req_options must not set request_timeout; " <>
               "use the client's own timeout option instead"
  end

  test "req_options cannot override the timeout through finch options" do
    for key <- [:receive_timeout, :request_timeout],
        finch <- [[{key, 5}], [{:pool_size, 2}, {key, 5}]] do
      assert {:error, %Error{message: message}} = new_client(req_options: [finch: finch])

      assert message =~ "req_options must not set"
      assert message =~ "finch"
      assert message =~ Atom.to_string(key)
      assert message =~ "use the client's own timeout option instead"
    end
  end

  # Green when written: pins the non-deprecated pool-timeout route (spec §4 R2).
  test "finch options that leave the timeout alone stay accepted" do
    for finch <- [[pool_timeout: 1_000], [pool_size: 2]] do
      assert {:ok, %TypeSafe.Client{}} = new_client(req_options: [finch: finch])
    end
  end

  # §11 S3c #58 (Gate 4 N1): :gen_tcp encodes the timeout in 32 bits.
  # The largest value is accepted today, so this one is green when written.
  test "the largest timeout, 4_294_967_295, is accepted at new/1 and per call" do
    for function <- @functions do
      {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), timeout: 4_294_967_295)
      assert {:ok, _data} = call(function, client, [])
      assert receive_timeouts() == [4_294_967_295]

      {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), [])
      assert {:ok, _data} = call(function, client, timeout: 4_294_967_295)
      assert receive_timeouts() == [4_294_967_295]
    end
  end

  test "a timeout above 4_294_967_295 is rejected at new/1 and per call, naming the bound" do
    for bad <- [4_294_967_296, 2 ** 64] do
      expected = "timeout must be at most 4294967295 ms, got #{bad}"

      assert {:error, %Error{message: ^expected}} = new_client(timeout: bad)

      for function <- @functions do
        {:ok, client} = stub_client(StubAdapter.respond(200, @ok_body), [])

        assert {:error, %Error{message: ^expected}} = call(function, client, timeout: bad)
        assert drain_sent() == []
      end
    end
  end

  # §11 S3c #59 (Gate 4 N3): Req raises ArgumentError for this pair on the
  # first request, and the SDK never raises, so new/1 rejects it up front.
  test "finch together with connect_options is rejected at new/1, and each alone is accepted" do
    for finch <- [[pool_timeout: 1_000], [pool_size: 2]] do
      assert {:error, %Error{message: message}} =
               new_client(req_options: [finch: finch, connect_options: [timeout: 300]])

      assert message =~ "req_options"
      assert message =~ "finch"
      assert message =~ "connect_options"
    end

    assert {:ok, %TypeSafe.Client{}} = new_client(req_options: [finch: [pool_timeout: 1_000]])
    assert {:ok, %TypeSafe.Client{}} = new_client(req_options: [connect_options: [timeout: 300]])
  end

  describe "resolved req_options (§11 S3c #60, Gate 4 second REJECT, option A')" do
    # Req collapses a keyword list last-wins (req.ex:590-598), so the invariant
    # is asserted on the resolved `client.req.options`, never on the input.
    @timeout_keys [:receive_timeout, :request_timeout]

    defp resolved_violations(options) do
      finch = Map.get(options, :finch)
      finch_options = if Keyword.keyword?(finch), do: finch, else: []

      top = for key <- @timeout_keys, Map.has_key?(options, key), do: {:top, key}
      nested = for key <- @timeout_keys, Keyword.has_key?(finch_options, key), do: {:finch, key}
      top ++ nested ++ pair_violation(finch, options)
    end

    defp pair_violation(nil, _options), do: []

    defp pair_violation(_finch, options) do
      if Map.has_key?(options, :connect_options), do: [:finch_with_connect_options], else: []
    end

    defp resolved_options(req_options) do
      case new_client(req_options: req_options) do
        {:ok, client} -> {:ok, client.req.options}
        {:error, %Error{}} = rejected -> rejected
      end
    end

    @entries [
      [finch: [pool_size: 2]],
      [finch: [receive_timeout: 5]],
      [finch: [request_timeout: 5]],
      [finch: :some_pool],
      [receive_timeout: 1],
      [request_timeout: 2],
      [connect_options: [timeout: 1]],
      [connect_options: [timeout: 2]]
    ]

    defp sequences do
      pairs = for a <- @entries, b <- @entries, do: a ++ b
      triples = for a <- @entries, b <- @entries, c <- @entries, do: a ++ b ++ c
      @entries ++ pairs ++ triples
    end

    test "no accepted req_options resolves to a caller timeout override" do
      for req_options <- sequences() do
        case resolved_options(req_options) do
          {:error, %Error{}} ->
            :ok

          {:ok, options} ->
            assert resolved_violations(options) == [],
                   "accepted #{inspect(req_options)}, which resolves to " <>
                     inspect(Map.take(options, [:finch, :connect_options | @timeout_keys]))
        end
      end
    end

    test "the named rows are rejected or resolve cleanly, and never raise" do
      rows = [
        [finch: [pool_size: 2], finch: [receive_timeout: 5]],
        [finch: [receive_timeout: 5], finch: [pool_size: 2]],
        [finch: [pool_size: 2], finch: [request_timeout: 5]],
        [finch: :some_pool, finch: [receive_timeout: 5]],
        [receive_timeout: 1, receive_timeout: 2],
        [connect_options: [timeout: 1], connect_options: [timeout: 2], finch: [pool_size: 2]]
      ]

      for row <- rows do
        case resolved_options(row) do
          {:error, %Error{}} -> :ok
          {:ok, options} -> assert resolved_violations(options) == [], inspect(row)
        end
      end
    end

    test "the reviewer's repro and its request_timeout and atom variants are rejected" do
      assert {:error, %Error{}} =
               new_client(req_options: [finch: [pool_size: 2], finch: [receive_timeout: 5]])

      assert {:error, %Error{}} =
               new_client(req_options: [finch: [pool_size: 2], finch: [request_timeout: 5]])

      assert {:error, %Error{}} =
               new_client(req_options: [finch: :some_pool, finch: [receive_timeout: 5]])

      assert {:error, %Error{}} =
               new_client(req_options: [receive_timeout: 1, receive_timeout: 2])
    end

    # Green today: A' must not turn duplicates into an error, or `base ++
    # overrides` composition (which Req supports) would break.
    test "a benign duplicate stays accepted, and Req keeps the last value" do
      assert {:ok, %{finch: [pool_size: 3]}} =
               resolved_options(finch: [pool_size: 2], finch: [pool_size: 3])

      # Spec §4 A': Req keeps the last `finch:`, so a timeout in an earlier,
      # overridden entry is not an override and must not be rejected.
      assert {:ok, %{finch: [pool_size: 2]}} =
               resolved_options(finch: [receive_timeout: 5], finch: [pool_size: 2])
    end

    test "the request the adapter sees carries no finch timeout override" do
      for row <- [
            [finch: [pool_size: 2], finch: [receive_timeout: 5]],
            [finch: [receive_timeout: 5], finch: [pool_size: 2]]
          ] do
        case new_client(timeout: 2_000, req_options: [adapter: StubAdapter] ++ row) do
          {:error, %Error{}} ->
            :ok

          {:ok, client} ->
            client = StubAdapter.put_stub(client, StubAdapter.respond(200, @ok_body))

            assert {:ok, _data} = TypeSafe.list_models(client)
            assert [request] = drain_sent()
            assert request.options[:receive_timeout] == 2_000
            finch = request.options[:finch] || []
            assert Enum.filter(@timeout_keys, &Keyword.has_key?(finch, &1)) == [], inspect(row)
        end
      end
    end
  end
end
