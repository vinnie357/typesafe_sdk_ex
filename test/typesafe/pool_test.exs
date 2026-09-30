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
  # of one connection started for this test only. A HOLDER call takes the only
  # connection (default pool timeout, long receive timeout) and the test waits
  # until the server reports the accept. Only then do the WAITER calls run with
  # a short `pool_timeout`, so which call waits is decided by construction, not
  # by a race that CPU load can flip.

  alias TypeSafe.Error
  alias TypeSafe.StubAdapter

  @pool_timeout_ms 50
  # The holder outlives the test; it is shut down at the end of each test.
  @holder_timeout_ms 5_000
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

  # One Finch pool with a single connection per host, private to this test.
  defp start_pool do
    name = :"typesafe_pool_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({Finch, name: name, pools: %{default: [size: 1, count: 1]}})
    name
  end

  defp client(port, finch_options, timeout) do
    {:ok, client} =
      TypeSafe.new(
        api_key: "k",
        base_url: "http://127.0.0.1:#{port}",
        timeout: timeout,
        req_options: [finch: finch_options],
        get_env: fn _name -> nil end
      )

    client
  end

  # Takes the pool's only connection and keeps it until the caller shuts the
  # task down. Returns once the server has accepted the connection.
  defp start_holder(port, name, call) do
    holder_client = client(port, [name: name], @holder_timeout_ms)
    holder = Task.async(fn -> call.(holder_client, []) end)
    assert_receive :accepted, 5_000
    holder
  end

  defp waiter_client(port, name) do
    client(port, [name: name, pool_timeout: @pool_timeout_ms], @holder_timeout_ms)
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
    |> Task.await_many(10_000)
  end

  defp system_one(client, opts), do: TypeSafe.system_one(client, @request, opts)
  defp list_models(client, opts), do: TypeSafe.list_models(client, opts)

  defp assert_pool_timeout_without_retry(call) do
    port = start_silent_server()
    name = start_pool()
    count_queue_exceptions(name)
    holder = start_holder(port, name, call)
    waiter = waiter_client(port, name)

    assert [{:error, %Error.Connection{} = error}] =
             concurrently(1, fn -> call.(waiter, retry: @quick_retries) end)

    assert error.reason == :pool_timeout
    assert error.message == @pool_timeout_message
    assert is_exception(error)

    # One failed checkout in total. A retry would queue and fail again while the
    # holder still has the connection.
    assert_received {:queue_exception, ^name}
    refute_received {:queue_exception, _name}

    Task.shutdown(holder, :brutal_kill)
  end

  test "system_one/3 returns a pool_timeout Connection error, without retrying it" do
    assert_pool_timeout_without_retry(&system_one/2)
  end

  test "list_models/2 returns a pool_timeout Connection error, without retrying it" do
    assert_pool_timeout_without_retry(&list_models/2)
  end

  test "with more callers than connections, every waiter returns a pool_timeout error" do
    port = start_silent_server()
    name = start_pool()
    holder = start_holder(port, name, &list_models/2)
    waiter = waiter_client(port, name)

    results = concurrently(5, fn -> list_models(waiter, []) end)

    assert Enum.frequencies(Enum.map(results, &outcome/1)) == %{pool_timeout: 5}

    Task.shutdown(holder, :brutal_kill)
  end

  defp outcome({:error, %Error.Connection{reason: :pool_timeout}}), do: :pool_timeout
  defp outcome({:raised, exception}), do: {:raised, exception.__struct__}
  defp outcome(other), do: other

  # Guard, green today: the rescue is scoped to the pool-checkout error and must
  # not turn other raises into errors.
  test "guard: a RuntimeError that is not the pool-checkout error still raises" do
    stub = fn _request -> raise RuntimeError, "adapter boom" end
    assert {:ok, client} = StubAdapter.client(stub)

    assert_raise RuntimeError, "adapter boom", fn -> TypeSafe.list_models(client) end
    assert_raise RuntimeError, "adapter boom", fn -> TypeSafe.system_one(client, @request) end
  end
end
