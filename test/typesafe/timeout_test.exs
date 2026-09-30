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

      assert_receive {:listening, listen, port}, 1_000
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
end
