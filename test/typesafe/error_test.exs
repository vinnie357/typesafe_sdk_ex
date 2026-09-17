defmodule TypeSafe.ErrorTest do
  use ExUnit.Case, async: true

  alias TypeSafe.StubAdapter

  # docs/spec.md §11 S2 #1 (errors.test.ts:20-40; 529 is new, from api.md:L319).
  # Also covers the general "every error is an Exception" check: §6 documents
  # a shared field contract (status, body, headers, request_id, message) but
  # names no literal shared Elixir struct/protocol the way JS's class chain
  # does — see the report for this ambiguity. is_exception/1 plus
  # Exception.message/1 is the closest Elixir equivalent of "inherits from a
  # common base" that the spec text actually supports.
  test "maps status to struct" do
    cases = [
      {400, TypeSafe.Error.BadRequest},
      {401, TypeSafe.Error.Authentication},
      {403, TypeSafe.Error.PermissionDenied},
      {404, TypeSafe.Error.NotFound},
      {422, TypeSafe.Error.UnprocessableEntity},
      {429, TypeSafe.Error.RateLimit},
      {500, TypeSafe.Error.InternalServer},
      {503, TypeSafe.Error.InternalServer},
      {529, TypeSafe.Error.InternalServer},
      {418, TypeSafe.Error.API}
    ]

    for {status, expected_module} <- cases do
      assert {:ok, client} = StubAdapter.client(StubAdapter.respond(status, ~s({})))
      assert {:error, error} = TypeSafe.list_models(client)

      assert error.__struct__ == expected_module
      assert error.status == status
      assert is_exception(error)
      assert Exception.message(error) == error.message
    end
  end

  # docs/spec.md §11 S2 #2+#3 (errors.test.ts:43-57) — combined, same JS test.
  test "every API error carries status, body, headers, request_id; message uses error.message" do
    assert {:ok, client} =
             StubAdapter.client(
               StubAdapter.respond(401, ~s({"error":{"message":"invalid api key"}}), [
                 {"content-type", "application/json"},
                 {"x-typesafe-request-id", "req_123"}
               ])
             )

    assert {:error, error} = TypeSafe.list_models(client)

    assert error.status == 401
    assert error.body == %{"error" => %{"message" => "invalid api key"}}
    assert error.request_id == "req_123"
    assert error.headers["x-typesafe-request-id"] == ["req_123"]
    assert error.message == "401 invalid api key"
    assert Exception.message(error) == "401 invalid api key"
  end

  # docs/spec.md §11 S2 #4 (errors.test.ts:59-89).
  test "message extraction from error/message/detail shapes" do
    cases = [
      {~s({"error":"plain string"}), "plain string"},
      {~s({"message":"top-level message"}), "top-level message"},
      {~s({"detail":"fastapi style"}), "fastapi style"},
      {~s({"detail":{"error_type":"api_usage_error","message":"Unknown model: x"}}),
       "Unknown model: x"},
      {~s({"detail":[{"type":"list_type","loc":["body","questions","q","score","criteria"],"msg":"Input should be a valid list"},{"type":"too_short","loc":["body","questions"],"msg":"Dictionary should have at least 1 item"}]}),
       "questions.q.score.criteria: Input should be a valid list; questions: Dictionary should have at least 1 item"}
    ]

    for {body, expected_detail} <- cases do
      assert {:ok, client} = StubAdapter.client(StubAdapter.respond(400, body))
      assert {:error, error} = TypeSafe.list_models(client)

      assert error.message == "400 " <> expected_detail
    end
  end

  # docs/spec.md §11 S2 #5+#6 (errors.test.ts:91-101) — combined, same JS
  # describe block. Elixir uses the ORIGINAL response body text here, not a
  # re-encoded term (spec §6, §12 q17), so the fixture bodies below are
  # already the raw wire text the message must reproduce verbatim.
  test "message falls back to the raw body text when nothing is extractable, truncated to 200 chars" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(400, ~s({"code":7})))
    assert {:error, short_error} = TypeSafe.list_models(client)
    assert short_error.message == ~s(400 {"code":7})

    long_body = ~s({"blob":") <> String.duplicate("x", 500) <> ~s("})
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(400, long_body))
    assert {:error, long_error} = TypeSafe.list_models(client)

    assert String.length(long_error.message) == String.length("400 ") + 200 + 1
    assert String.ends_with?(long_error.message, "…")
  end

  # docs/spec.md §11 S2 #7 (errors.test.ts:104-115).
  test "a non-JSON error body is kept as text" do
    assert {:ok, client} =
             StubAdapter.client(
               StubAdapter.respond(502, "<h1>bad gateway</h1>", [{"content-type", "text/html"}])
             )

    assert {:error, %TypeSafe.Error.InternalServer{} = error} = TypeSafe.list_models(client)

    assert error.body == "<h1>bad gateway</h1>"
    assert error.message == "502 <h1>bad gateway</h1>"
  end

  # docs/spec.md §11 S2 #8 (errors.test.ts:117-125).
  test "an empty error body gives \"<status> status code (no body)\" with a nil body" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(429, ""))

    assert {:error, %TypeSafe.Error.RateLimit{} = error} = TypeSafe.list_models(client)

    assert error.body == nil
    assert error.message == "429 status code (no body)"
  end

  # docs/spec.md §11 S2 #9 (reliability.test.ts:538-545). Uses the same
  # Retry-After parser as §5 — "7" seconds -> 7000 ms.
  test "RateLimit exposes retry_after_ms parsed from Retry-After" do
    assert {:ok, client} =
             StubAdapter.client(StubAdapter.respond(429, ~s({}), [{"retry-after", "7"}]))

    assert {:error, %TypeSafe.Error.RateLimit{retry_after_ms: 7000}} =
             TypeSafe.list_models(client)
  end

  # docs/spec.md §11 S2 #10 (reliability.test.ts:547-553).
  test "RateLimit retry_after_ms is nil when Retry-After is absent" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(429, ~s({}), []))

    assert {:error, %TypeSafe.Error.RateLimit{retry_after_ms: nil}} =
             TypeSafe.list_models(client)
  end

  # docs/spec.md §11 S2 #11 (client.test.ts:249-259). verified:
  # Exception.message(Req.TransportError.exception(reason: :closed)) ==
  # "socket closed", so the Connection message ("Connection error: <cause>",
  # §6) is "Connection error: socket closed" for this reason.
  test "a :closed transport error becomes Connection, keeping the reason and cause in the message" do
    test_pid = self()

    stub = fn request ->
      send(test_pid, {:sent, request})
      {request, Req.TransportError.exception(reason: :closed)}
    end

    assert {:ok, client} = StubAdapter.client(stub)

    assert {:error, %TypeSafe.Error.Connection{reason: :closed} = error} =
             TypeSafe.list_models(client)

    assert error.message == "Connection error: socket closed"
  end

  # docs/spec.md §11 S2 #12 (reliability.test.ts:445-458). client.timeout has
  # no override option yet (S3), so the configured duration is today's fixed
  # default, 10_000.
  test "a :timeout transport error becomes Timeout with the configured duration" do
    test_pid = self()

    stub = fn request ->
      send(test_pid, {:sent, request})
      {request, Req.TransportError.exception(reason: :timeout)}
    end

    assert {:ok, client} = StubAdapter.client(stub)

    assert {:error, %TypeSafe.Error.Timeout{timeout_ms: 10_000} = error} =
             TypeSafe.list_models(client)

    assert error.message == "Request timed out after 10000ms."
  end

  # docs/spec.md §11 S2 #13 (client.test.ts:176-185). Regression guard, NOT a
  # red pin: per §6's last row ("config, validation, or bad /v1/models shape"
  # -> generic TypeSafe.Error), this behavior already shipped in S1 (the B1
  # tests in client_test.exs) and is expected to stay green once this file
  # compiles — verified via a scratch script (bypassing this file's other
  # not-yet-existing structs) that all six shapes below already return this
  # exact message today. Kept here, not duplicated in client_test.exs, so §6's
  # full error-taxonomy AC ("every row... covered by at least one test") is
  # satisfied from one file; client_test.exs/questions_test.exs are untouched.
  test "list_models unexpected shape stays the generic TypeSafe.Error" do
    bodies = [
      ~s(null),
      ~s([]),
      ~s({"models":{"models":[]}}),
      ~s({"models":null}),
      ~s({"models":"bad"}),
      ~s({"ok":true})
    ]

    for body <- bodies do
      assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, body))
      assert {:error, %TypeSafe.Error{message: message}} = TypeSafe.list_models(client)
      assert message =~ "Unexpected response shape from GET /v1/models"
    end
  end

  # Operator ask (not a numbered §11 item): the API key must never leak into
  # an error struct or its message.
  test "the api key never appears in an error struct or its message" do
    assert {:ok, client} =
             StubAdapter.client(
               StubAdapter.respond(401, ~s({"error":"invalid"})),
               api_key: "super-secret-key"
             )

    assert {:error, error} = TypeSafe.list_models(client)

    refute inspect(error, limit: :infinity, printable_limit: :infinity) =~ "super-secret-key"
    refute error.message =~ "super-secret-key"
  end

  # Operator ask (not a numbered §11 item): the live API resolves a
  # requested model alias to a concrete version on success (observed:
  # request "jev-latest" -> response "model": "jev-1.13.0"). Regression
  # guard, NOT a red pin: §3 already documents the success body as
  # "returned unvalidated," and S2 only touches the non-2xx branches of
  # handle_response/handle_list_models_response, so this should already be
  # (and stay) green — confirmed against the existing S1 implementation.
  test "a successful system_one response preserves a resolved model field" do
    body =
      ~s({"model":"jev-1.13.0","answers":{"q1":{"type":"noul","noul":0.5}},"usage":{"input_tokens":1,"output_tokens":1}})

    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, body))

    assert {:ok, result} =
             TypeSafe.system_one(client, %{state: "s", questions: %{q1: TypeSafe.noul("?")}})

    assert result["model"] == "jev-1.13.0"
  end
end
