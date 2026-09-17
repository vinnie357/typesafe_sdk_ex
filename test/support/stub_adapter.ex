defmodule TypeSafe.StubAdapter do
  @moduledoc """
  Req module adapter used by tests in place of real HTTP (spec `docs/spec.md` §9a, §11).

  `run/1` reads a stub closure from the request's private data and calls it instead of
  making a real request. Because the closure lives in `request.private`, there is no
  global or process-dictionary state, so the stub is safe under `async: true`, and the
  private data survives retries (Req re-runs request steps and the adapter on each retry
  attempt against the same request struct).

  A module adapter is required, not a function adapter: Req 0.7.4 prints a deprecation
  warning on stderr for every function adapter, which would break the clean-test-output
  rule (spec §11).
  """

  @doc "Req adapter callback: dispatch to the stub closure stored under `:typesafe_stub`."
  def run(request) do
    Req.Request.get_private(request, :typesafe_stub).(request)
  end

  @doc """
  Build `{:ok, client}` via `TypeSafe.new/1` with this module wired as the Req adapter
  and `stub` installed as the private closure `run/1` reads.

  `opts` are passed through to `TypeSafe.new/1` with a default `api_key` and a
  `get_env` that never reads real process environment, so callers only need to
  override what the test cares about.
  """
  def client(stub, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:api_key, "k")
      |> Keyword.put_new(:get_env, fn _name -> nil end)
      |> Keyword.update(:req_options, [adapter: __MODULE__], fn req_opts ->
        Keyword.put_new(req_opts, :adapter, __MODULE__)
      end)

    {:ok, client} = TypeSafe.new(opts)
    {:ok, put_stub(client, stub)}
  end

  @doc """
  Wire `stub` onto an already-built `client` (e.g. one built directly via
  `TypeSafe.new/1` with `req_options: [adapter: TypeSafe.StubAdapter]`, for a
  test that needs to assert on `TypeSafe.new/1`'s return value before sending
  any request). Returns the client with the closure installed, not wrapped in
  a tagged tuple, since `client` is already a plain struct here.
  """
  def put_stub(client, stub) do
    %{client | req: Req.Request.put_private(client.req, :typesafe_stub, stub)}
  end

  @doc """
  A stub that answers every call with `status`/`body`/`headers` and reports the request
  to the calling test process as `{:sent, request}`, so tests can `assert_received` or
  `refute_received` on it.
  """
  def respond(status, body, headers \\ [{"content-type", "application/json"}]) do
    test_pid = self()

    fn request ->
      send(test_pid, {:sent, request})
      {request, Req.Response.new(status: status, headers: headers, body: body)}
    end
  end
end
