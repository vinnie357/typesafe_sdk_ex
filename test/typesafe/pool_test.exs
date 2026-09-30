defmodule TypeSafe.PoolTest do
  use ExUnit.Case, async: true

  # Issue #12 (operator decision, 2026-09-30: blocks v0.2.0). When the Finch
  # pool cannot hand out a connection within `pool_timeout`, Finch re-raises the
  # NimblePool checkout exit as a `RuntimeError`
  # (finch@0.24.0 lib/finch/http1/pool.ex:81-89), and Req does not catch it.
  # ADR 0006 decision 15: the SDK returns `TypeSafe.Error.Connection` with
  # `reason: :pool_timeout` and does not retry it.
  #
  # Shape: a loopback server that accepts and never answers, plus a Finch pool
  # of one connection started for this test only. Two concurrent calls: one
  # takes the only connection and waits out its receive timeout, the other
  # waits `pool_timeout` for a connection and fails. Which call is which is a
  # race, so the assertions read the pair of outcomes, not their order.

  alias TypeSafe.Error
  alias TypeSafe.StubAdapter

  @pool_timeout_ms 40
  # Long enough that the connection stays taken while the waiting call fails and
  # would retry, short enough to keep the module well under a second.
  @receive_timeout_ms 200
  @request %{state: "s", questions: %{"q" => TypeSafe.noul("q")}}
  # Retries that would fire within milliseconds if a pool timeout were retried.
  @quick_retries [max_retries: 3, backoff_initial_ms: 1, backoff_max_ms: 1, backoff_jitter: 0]

  @pool_timeout_message "Connection error: connection pool exhausted " <>
                          "(no connection available within the pool timeout)"

  # A long-lived acceptor owns the listener and accepts in a loop, one linked
  # process per connection that holds the socket and never reads or replies
  # (the shape ADR 0012 and timeout_test.exs use). Port 0, so tests cannot
  # collide. The supervisor ends the acceptor, and the links end the handlers.
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
             accept_loop(listen)
           end},
          id: make_ref()
        )
      )

    assert_receive {:listening, port}, 5_000
    port
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        handler =
          spawn_link(fn ->
            receive do
              :never -> :ok
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, handler)
        accept_loop(listen)

      {:error, _closed} ->
        :ok
    end
  end

  # One Finch pool with a single connection per host, private to this test.
  defp pool_client(port) do
    name = :"typesafe_pool_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({Finch, name: name, pools: %{default: [size: 1, count: 1]}})

    {:ok, client} =
      TypeSafe.new(
        api_key: "k",
        base_url: "http://127.0.0.1:#{port}",
        timeout: @receive_timeout_ms,
        req_options: [finch: [name: name, pool_timeout: @pool_timeout_ms]],
        get_env: fn _name -> nil end
      )

    {name, client}
  end

  # The queue-exception event is how the test counts checkout attempts that
  # failed: one per waiting attempt, so a retry would add more.
  def forward_queue_exception(_event, _measurements, %{name: name}, %{test: test, name: name}) do
    send(test, {:queue_exception, name})
  end

  def forward_queue_exception(_event, _measurements, _metadata, _config), do: :ok

  defp count_queue_exceptions(name) do
    handler_id = {__MODULE__, name}

    :ok =
      :telemetry.attach(
        handler_id,
        [:finch, :queue, :exception],
        &__MODULE__.forward_queue_exception/4,
        %{test: self(), name: name}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Runs `fun` in `count` tasks at once; a raise comes back as data so a failure
  # reads as a wrong outcome, not as an exit of the test process.
  defp concurrently(count, fun) do
    1..count
    |> Enum.map(fn _ ->
      Task.async(fn ->
        try do
          fun.()
        rescue
          exception -> {:raised, exception}
        end
      end)
    end)
    |> Task.await_many(5_000)
  end

  defp outcome({:error, %Error.Connection{reason: :pool_timeout}}), do: :pool_timeout
  defp outcome({:error, %Error.Timeout{}}), do: :timeout
  defp outcome({:raised, exception}), do: {:raised, exception.__struct__}
  defp outcome(other), do: other

  defp pool_timeout_error({:error, %Error.Connection{reason: :pool_timeout} = error}), do: error

  test "system_one/3 returns a pool_timeout Connection error, without retrying it" do
    {name, client} = client_for_test()
    count_queue_exceptions(name)

    results =
      concurrently(2, fn ->
        TypeSafe.system_one(client, @request, retry: @quick_retries)
      end)

    assert Enum.sort(Enum.map(results, &outcome/1)) == [:pool_timeout, :timeout]

    error = results |> Enum.find(&(outcome(&1) == :pool_timeout)) |> pool_timeout_error()
    assert error.message == @pool_timeout_message
    assert is_exception(error)

    # One failed checkout in total. A retry would queue and fail again while the
    # other call still holds the connection.
    assert_received {:queue_exception, ^name}
    refute_received {:queue_exception, _name}
  end

  test "list_models/2 returns a pool_timeout Connection error, without retrying it" do
    {name, client} = client_for_test()
    count_queue_exceptions(name)

    results = concurrently(2, fn -> TypeSafe.list_models(client, retry: @quick_retries) end)

    assert Enum.sort(Enum.map(results, &outcome/1)) == [:pool_timeout, :timeout]

    error = results |> Enum.find(&(outcome(&1) == :pool_timeout)) |> pool_timeout_error()
    assert error.message == @pool_timeout_message

    assert_received {:queue_exception, ^name}
    refute_received {:queue_exception, _name}
  end

  test "with more callers than connections, every call returns a tagged tuple" do
    {_name, client} = client_for_test()

    results = concurrently(6, fn -> TypeSafe.list_models(client) end)

    assert Enum.frequencies(Enum.map(results, &outcome/1)) == %{timeout: 1, pool_timeout: 5}
  end

  # Guard, green today: the rescue is scoped to the pool-checkout error and must
  # not turn other raises into errors.
  test "guard: a RuntimeError that is not the pool-checkout error still raises" do
    stub = fn _request -> raise RuntimeError, "adapter boom" end
    assert {:ok, client} = StubAdapter.client(stub)

    assert_raise RuntimeError, "adapter boom", fn -> TypeSafe.list_models(client) end
    assert_raise RuntimeError, "adapter boom", fn -> TypeSafe.system_one(client, @request) end
  end

  defp client_for_test do
    pool_client(start_silent_server())
  end
end
