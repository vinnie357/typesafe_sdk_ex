defmodule TypeSafe.DefaultLoggerTest do
  # Issue #13, slice 0: the opt-in default logger.
  #
  # async: false, for two pieces of shared state no test can isolate:
  #   1. the telemetry handler id "typesafe-default-logger" is VM-global, and every
  #      SDK call in the VM would run it while it is attached;
  #   2. the global Logger level. config/test.exs sets `level: :none`, so
  #      `capture_log/2` sees nothing unless the level is raised for the test.
  # Both are restored in `on_exit`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TypeSafe.StubAdapter

  @ok_body ~s({"models":[]})
  @secret "tsk_0123456789abcdef"

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      _result = detach()
      Logger.configure(level: previous)
    end)

    :ok
  end

  # `TypeSafe.attach_default_logger/1` does not exist until the implementation
  # lands; going through `apply/3` keeps the file compiling (see telemetry_test.exs).
  defp typesafe(fun, args), do: apply(TypeSafe, fun, args)
  defp attach(opts), do: typesafe(:attach_default_logger, [opts])
  defp detach, do: typesafe(:detach_default_logger, [])

  defp client(opts) do
    retry = [backoff_initial_ms: 0, backoff_max_ms: 0]
    {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @ok_body), [retry: retry] ++ opts)
    client
  end

  defp logged(client) do
    capture_log([level: :debug], fn -> assert {:ok, []} = TypeSafe.list_models(client) end)
  end

  test "attach and detach return telemetry's own results" do
    assert :ok = typesafe(:attach_default_logger, [])
    assert {:error, :already_exists} = attach([])
    assert :ok = detach()
    assert {:error, :not_found} = detach()
  end

  test "an unknown option is an error value, and nothing is attached" do
    assert {:error, %TypeSafe.Error{}} = attach(bogus: 1)
    assert {:error, :not_found} = detach()
  end

  test "while attached, an :info client's call is logged at :info with the prefix" do
    assert :ok = attach([])

    log = logged(client(log_level: :info))

    assert log =~ ~r{\[info\] \[typesafe-sdk\] #\d+ GET /v1/models <- 200 in \d+ms}
  end

  test "while attached, a :warning client's call is not logged" do
    assert :ok = attach([])

    refute logged(client(log_level: :warning)) =~ "[typesafe-sdk]"
  end

  test "while attached, a :debug client's call is logged with a redacted request line" do
    assert :ok = attach([])

    log = logged(client(log_level: :debug, api_key: @secret))

    assert log =~ ~r{\[debug\] \[typesafe-sdk\] #\d+ GET /v1/models -> }
    assert log =~ "[typesafe-sdk] #"
    assert log =~ " -> "
    assert log =~ "Bearer ***"
    refute log =~ @secret
  end

  test "after detach, an :info client's call is not logged" do
    assert :ok = attach([])
    assert :ok = detach()

    refute logged(client(log_level: :info)) =~ "[typesafe-sdk]"
  end
end
