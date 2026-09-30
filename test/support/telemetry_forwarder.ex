defmodule TypeSafe.TelemetryForwarder do
  @moduledoc """
  Test helper: forwards the SDK's `:telemetry` events to the test process (issue #13).

  Telemetry handlers are global, so the handler forwards an event only when it fired in
  the test process itself or in a process the test spawned (`Task.async/1` records the
  test pid in `$callers`). That keeps every test that uses it safe under `async: true`:
  it only ever sees its own events, and a handler attached by one test is inert for
  every other test's processes.
  """

  @events [
    [:typesafe, :attempt, :start],
    [:typesafe, :attempt, :stop],
    [:typesafe, :request, :retry]
  ]

  @doc "Attaches a forwarder for `test_pid` under a unique id. Returns the id, for `:telemetry.detach/1`."
  def attach(test_pid) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(id, @events, &__MODULE__.handle/4, test_pid)
    id
  end

  @doc false
  def handle(event, measurements, metadata, test_pid) do
    case self() == test_pid or test_pid in Process.get(:"$callers", []) do
      true -> send(test_pid, {:telemetry, event, measurements, metadata})
      false -> :ok
    end
  end

  @doc "Returns every forwarded event received so far, oldest first, as `{event, measurements, metadata}`."
  def drain(acc \\ []) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        drain([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
