defmodule TypeSafe.ClientTest do
  use ExUnit.Case, async: true

  alias TypeSafe.StubAdapter

  @system_one_response ~s({"model":"m","answers":{"q1":{"type":"noul","noul":0.5}},"usage":{"input_tokens":1,"output_tokens":1}})

  @default_retry_policy %TypeSafe.RetryPolicy{
    max_retries: 2,
    backoff_initial_ms: 500,
    backoff_max_ms: 5000,
    backoff_jitter: 0.25,
    http_statuses: MapSet.new([408, 429] ++ Enum.to_list(500..599)),
    respect_retry_after: true,
    max_retry_after_ms: 60_000,
    api_connection_error: true,
    api_timeout_error: true
  }

  # docs/spec.md §11 S1 #1 (client.test.ts:100-103)
  test "new/1 without api_key or env returns error naming TYPESAFE_API_KEY" do
    assert {:error, %TypeSafe.Error{message: message}} =
             TypeSafe.new(get_env: fn _name -> nil end)

    assert message =~ "TYPESAFE_API_KEY"
  end

  # docs/spec.md §11 S1 #2 (client.test.ts:44-51)
  test "new/1 falls back to defaults" do
    assert {:ok, client} = TypeSafe.new(api_key: "k", get_env: fn _name -> nil end)

    assert client.base_url == "https://api.typesafe.ai"
    assert client.default_model == "jev-latest"
    assert client.log_level == :warning
    assert client.timeout == 10_000
    assert client.retry == @default_retry_policy
  end

  # docs/spec.md §11 S1 #3 (client.test.ts:53-63)
  test "new/1 reads every setting from env" do
    env = %{
      "TYPESAFE_API_KEY" => "env-key",
      "TYPESAFE_BASE_URL" => "https://env.test",
      "TYPESAFE_DEFAULT_MODEL" => "env-model",
      "TYPESAFE_LOG_LEVEL" => "debug"
    }

    assert {:ok, client} =
             TypeSafe.new(
               req_options: [adapter: StubAdapter],
               get_env: fn name -> Map.get(env, name) end
             )

    assert client.base_url == "https://env.test"
    assert client.default_model == "env-model"
    assert client.log_level == :debug

    client = StubAdapter.put_stub(client, StubAdapter.respond(200, ~s({"models":[]})))

    assert {:ok, []} = TypeSafe.list_models(client)
    assert_received {:sent, request}
    assert Req.Request.get_header(request, "authorization") == ["Bearer env-key"]
  end

  # docs/spec.md §11 S1 #4 (client.test.ts:65-80)
  test "new/1 prefers options over env" do
    env = %{
      "TYPESAFE_API_KEY" => "env-key",
      "TYPESAFE_BASE_URL" => "https://env.test",
      "TYPESAFE_DEFAULT_MODEL" => "env-model",
      "TYPESAFE_LOG_LEVEL" => "debug"
    }

    assert {:ok, client} =
             TypeSafe.new(
               api_key: "code-key",
               base_url: "https://code.test",
               default_model: "code-model",
               log_level: :error,
               req_options: [adapter: StubAdapter],
               get_env: fn name -> Map.get(env, name) end
             )

    assert client.base_url == "https://code.test"
    assert client.default_model == "code-model"
    assert client.log_level == :error

    client = StubAdapter.put_stub(client, StubAdapter.respond(200, ~s({"models":[]})))

    assert {:ok, []} = TypeSafe.list_models(client)
    assert_received {:sent, request}
    assert Req.Request.get_header(request, "authorization") == ["Bearer code-key"]
  end

  # docs/spec.md §11 S1 #5 (client.test.ts:89-98)
  test "new/1 treats blank and whitespace env values as unset" do
    env = %{
      "TYPESAFE_API_KEY" => "k",
      "TYPESAFE_BASE_URL" => "   ",
      "TYPESAFE_DEFAULT_MODEL" => "",
      "TYPESAFE_LOG_LEVEL" => ""
    }

    assert {:ok, client} = TypeSafe.new(get_env: fn name -> Map.get(env, name) end)

    assert client.base_url == "https://api.typesafe.ai"
    assert client.default_model == "jev-latest"
    assert client.log_level == :warning
  end

  # docs/spec.md §11 S1 #6 (client.test.ts:105-111)
  test "new/1 strips trailing slashes from base_url in option and env" do
    env = %{"TYPESAFE_API_KEY" => "k", "TYPESAFE_BASE_URL" => "https://example.test///"}

    assert {:ok, client1} = TypeSafe.new(get_env: fn name -> Map.get(env, name) end)
    assert client1.base_url == "https://example.test"

    assert {:ok, client2} =
             TypeSafe.new(api_key: "k", base_url: "https://x.test/", get_env: fn _name -> nil end)

    assert client2.base_url == "https://x.test"
  end

  # docs/spec.md §11 S1 #7 (client.test.ts:82-87)
  test "inspect(client) never contains the api key" do
    assert {:ok, client} = TypeSafe.new(api_key: "super-secret", get_env: fn _name -> nil end)

    refute inspect(client, limit: :infinity, printable_limit: :infinity) =~ "super-secret"
    refute Map.has_key?(client, :api_key)
  end

  # docs/spec.md §11 S1 AC(1) coverage gap (env.ts:16-19)
  test "new/1 treats a blank TYPESAFE_API_KEY as unset and returns an error" do
    env = %{"TYPESAFE_API_KEY" => "   "}

    assert {:error, %TypeSafe.Error{message: message}} =
             TypeSafe.new(get_env: fn name -> Map.get(env, name) end)

    assert message =~ "TYPESAFE_API_KEY"
  end

  # docs/spec.md §11 S1 #8 (client.test.ts:131-147)
  test "list_models sends auth and identifying headers" do
    assert {:ok, client} =
             StubAdapter.client(
               StubAdapter.respond(200, ~s({"models":[]})),
               base_url: "https://x.test",
               api_key: "secret"
             )

    assert {:ok, []} = TypeSafe.list_models(client)
    assert_received {:sent, request}

    assert request.url == URI.parse("https://x.test/v1/models")
    assert request.method == :get
    assert Req.Request.get_header(request, "authorization") == ["Bearer secret"]

    assert [user_agent] = Req.Request.get_header(request, "user-agent")
    assert user_agent =~ ~r/^typesafe-sdk.*\/#{Regex.escape(TypeSafe.version())}$/

    assert [sdk_header] = Req.Request.get_header(request, "x-typesafe-sdk")
    assert sdk_header =~ ~r/^typesafe-sdk.*\/#{Regex.escape(TypeSafe.version())}$/

    assert [runtime] = Req.Request.get_header(request, "x-typesafe-runtime")
    assert runtime != ""

    assert Req.Request.get_header(request, "accept") == ["application/json"]
    assert Req.Request.get_header(request, "content-type") == []
  end

  # docs/spec.md §11 S1 #9 (client.test.ts:164-174)
  test "list_models unwraps models" do
    cases = [
      {~s({"models": []}), []},
      {~s({"models": [{"name": "m", "description": "d", "release_date": "2026"}]}),
       [%{"name" => "m", "description" => "d", "release_date" => "2026"}]}
    ]

    for {body, expected} <- cases do
      assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, body))
      assert {:ok, ^expected} = TypeSafe.list_models(client)
    end
  end

  # docs/spec.md §11 S1 #10 (client.test.ts:187-195)
  test "list_models preserves unknown model fields" do
    body =
      ~s({"models": [{"name": "m", "description": "d", "release_date": "2026", "tags": ["internal"]}]})

    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, body))

    assert {:ok, [model]} = TypeSafe.list_models(client)
    assert model["name"] == "m"
    assert model["tags"] == ["internal"]
  end

  # docs/spec.md §11 S1 #11 (client.test.ts:197-210)
  test "system_one posts payload with default model and returns decoded body" do
    assert {:ok, client} =
             StubAdapter.client(
               StubAdapter.respond(200, @system_one_response),
               base_url: "https://x.test"
             )

    request_map = %{state: %{a: 1}, questions: %{q1: TypeSafe.noul("x")}}
    assert {:ok, result} = TypeSafe.system_one(client, request_map)
    assert_received {:sent, sent}

    assert sent.url == URI.parse("https://x.test/v1/systemone")
    assert sent.method == :post

    assert {:ok, decoded} = JSON.decode(IO.iodata_to_binary(sent.body))

    assert decoded == %{
             "state" => %{"a" => 1},
             "model" => "jev-latest",
             "questions" => %{"q1" => %{"type" => "noul", "instructions" => "x"}}
           }

    assert result["answers"]["q1"]["noul"] == 0.5
  end

  # docs/spec.md §11 S1 #12 (client.test.ts:212-234)
  test "system_one: explicit model wins, client default_model otherwise" do
    assert {:ok, client} =
             StubAdapter.client(
               StubAdapter.respond(200, @system_one_response),
               default_model: "client-default"
             )

    request = %{state: "s", questions: %{q: TypeSafe.choice("c", %{a: nil})}}

    assert {:ok, _result} = TypeSafe.system_one(client, request)
    assert_received {:sent, sent1}
    assert {:ok, %{"model" => "client-default"}} = JSON.decode(IO.iodata_to_binary(sent1.body))

    assert {:ok, _result} = TypeSafe.system_one(client, Map.put(request, :model, "per-call"))
    assert_received {:sent, sent2}
    assert {:ok, %{"model" => "per-call"}} = JSON.decode(IO.iodata_to_binary(sent2.body))
  end

  # docs/spec.md §11 S1 #13 (client.test.ts:413-426)
  test "system_one forwards extra top-level keys including nil" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))

    request = %{
      state: "s",
      questions: %{q: TypeSafe.score("?", ["low", "high"])},
      future_option: nil,
      nested: %{enabled: true}
    }

    assert {:ok, _result} = TypeSafe.system_one(client, request)
    assert_received {:sent, sent}
    assert {:ok, decoded} = JSON.decode(IO.iodata_to_binary(sent.body))

    assert decoded == %{
             "state" => "s",
             "model" => "jev-latest",
             "questions" => %{
               "q" => %{"type" => "score", "instructions" => "?", "criteria" => ["low", "high"]}
             },
             "future_option" => nil,
             "nested" => %{"enabled" => true}
           }
  end

  # docs/spec.md §11 S1 #14 (client.test.ts:149-162)
  test "headers: default and per-call merge, per-call wins, authorization is protected" do
    assert {:ok, client} =
             StubAdapter.client(
               StubAdapter.respond(200, ~s({"models":[]})),
               api_key: "secret",
               default_headers: %{
                 "X-Trace" => "client",
                 "X-Only-Default" => "yes",
                 "Authorization" => "nope"
               }
             )

    assert {:ok, []} =
             TypeSafe.list_models(client, headers: %{"X-Trace" => "call", "X-Only-Call" => "yes"})

    assert_received {:sent, request}
    assert Req.Request.get_header(request, "x-trace") == ["call"]
    assert Req.Request.get_header(request, "x-only-default") == ["yes"]
    assert Req.Request.get_header(request, "x-only-call") == ["yes"]
    assert Req.Request.get_header(request, "authorization") == ["Bearer secret"]
  end

  # docs/spec.md §11 S1 #15 (release-regressions.test.ts:15-58; the retry-count part is in S3)
  test "case-insensitive header overrides cannot change protected headers; content-type is application/json on POST" do
    assert {:ok, client} =
             StubAdapter.client(
               StubAdapter.respond(200, @system_one_response),
               api_key: "secret",
               default_headers: %{
                 "X-Team" => "default",
                 "authorization" => "bad",
                 "content-type" => "text/plain"
               }
             )

    assert {:ok, _result} =
             TypeSafe.system_one(
               client,
               %{state: "s", questions: %{q: TypeSafe.noul("?")}},
               headers: %{
                 "x-team" => "call",
                 "AUTHORIZATION" => "bad-again",
                 "ACCEPT" => "text/plain",
                 "USER-AGENT" => "bad",
                 "X-TYPESAFE-SDK" => "bad",
                 "X-TYPESAFE-RUNTIME" => "bad",
                 "CONTENT-TYPE" => "text/html"
               }
             )

    assert_received {:sent, request}
    assert Req.Request.get_header(request, "authorization") == ["Bearer secret"]
    assert Req.Request.get_header(request, "x-team") == ["call"]
    assert Req.Request.get_header(request, "content-type") == ["application/json"]
    assert Req.Request.get_header(request, "accept") == ["application/json"]

    assert [user_agent] = Req.Request.get_header(request, "user-agent")
    refute user_agent =~ "bad"
    assert [sdk_header] = Req.Request.get_header(request, "x-typesafe-sdk")
    refute sdk_header =~ "bad"
    assert [runtime] = Req.Request.get_header(request, "x-typesafe-runtime")
    refute runtime =~ "bad"
    assert runtime != ""
  end

  # docs/spec.md §11 S1 #16 (release-regressions.test.ts:60-70)
  test "GET strips caller content-type and retry-count headers" do
    assert {:ok, client} =
             StubAdapter.client(
               StubAdapter.respond(200, ~s({"models":[]})),
               default_headers: %{"content-type" => "bad", "x-typesafe-retry-count" => "99"}
             )

    assert {:ok, []} = TypeSafe.list_models(client)
    assert_received {:sent, request}
    assert Req.Request.get_header(request, "content-type") == []
    assert Req.Request.get_header(request, "x-typesafe-retry-count") == []
  end

  # docs/spec.md §11 S1 #17 (client.test.ts:398-411, api-promise.test.ts:21-32)
  test "with_response: true returns data, response, and request_id" do
    assert {:ok, client} =
             StubAdapter.client(
               StubAdapter.respond(200, @system_one_response, [
                 {"content-type", "application/json"},
                 {"x-typesafe-request-id", "req_1"}
               ])
             )

    assert {:ok, %{data: data, response: %Req.Response{status: 200}, request_id: "req_1"}} =
             TypeSafe.system_one(
               client,
               %{state: "s", questions: %{q1: TypeSafe.noul("?")}},
               with_response: true
             )

    assert {:ok, decoded} = JSON.decode(@system_one_response)
    assert data == decoded
  end

  # docs/spec.md §11 S1 #18 (api-promise.test.ts:34-39)
  test "with_response: request_id is nil when the header is absent" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))

    assert {:ok, %{request_id: nil}} =
             TypeSafe.system_one(
               client,
               %{state: "s", questions: %{q1: TypeSafe.noul("?")}},
               with_response: true
             )
  end

  # docs/spec.md §11 S1 #17 coverage gap (client.test.ts:164-174, api-promise.test.ts:21-39)
  test "with_response: true works for list_models too" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, ~s({"models":[]})))

    assert {:ok, %{data: [], response: %Req.Response{status: 200}, request_id: nil}} =
             TypeSafe.list_models(client, with_response: true)
  end

  # docs/spec.md §11 S1 #19 (errors.test.ts:127-133, success-path variant: new)
  test "body parsing decodes JSON sent without a content-type header" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response, []))

    assert {:ok, result} =
             TypeSafe.system_one(client, %{state: "s", questions: %{q1: TypeSafe.noul("?")}})

    assert {:ok, decoded} = JSON.decode(@system_one_response)
    assert result == decoded
  end

  # docs/spec.md §11 S1 #20 (release-regressions.test.ts:148-153, adapted)
  test "system_one on a 204 empty body returns {:ok, nil}" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(204, ""))

    assert {:ok, nil} =
             TypeSafe.system_one(client, %{state: "s", questions: %{q1: TypeSafe.noul("?")}})
  end

  describe "review fixes" do
    # Gate 4 review, PR #1, a935ea1: B1 (spec §3 L55, JS models.ts:23-28) — any
    # body other than {"models": [...]} must be an error, never a raise.
    test "B1: list_models errors instead of raising when the body is not a {models: [...]} map" do
      bodies = [
        ~s(<html>oops</html>),
        ~s([]),
        ~s(null),
        ~s({"ok":true}),
        ""
      ]

      for body <- bodies do
        assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, body))
        assert {:error, %TypeSafe.Error{message: message}} = TypeSafe.list_models(client)
        assert message =~ "Unexpected response shape from GET /v1/models"
      end
    end

    # Gate 4 review, PR #1, a935ea1: B1, the "models" key present but not a list.
    test "B1: list_models errors when \"models\" is present but not a list" do
      bodies = [~s({"models":"bad"}), ~s({"models":null})]

      for body <- bodies do
        assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, body))
        assert {:error, %TypeSafe.Error{message: message}} = TypeSafe.list_models(client)
        assert message =~ "Unexpected response shape from GET /v1/models"
      end
    end

    # Gate 4 review, PR #1, 2467975 + 4159f27 follow-up: B2 (spec §5 L154) —
    # Req's built-in default retry (`:safe_transient`) must never be active
    # on the client's request. The original "exactly once" call-count proof
    # was a delayed fuse: it broke the moment S3 legitimately retries a
    # retryable 503 (spec §5 L123/127/134 — default policy is max_retries 2,
    # 503 retryable), and its `%TypeSafe.Error{}` struct pattern broke the
    # moment S2 lands the status-mapped error taxonomy (spec §6 — a 503
    # becomes `TypeSafe.Error.InternalServer`, not `TypeSafe.Error`). The
    # 503/transport-error stub pair also turned out to be its own fuse: once
    # S3's real backoff is wired in, a stub that never stops erroring makes
    # Req actually sleep through every retry (measured ~1.3s each), which
    # both violates the no-sleep test rule and would push S3's own AC(4)
    # (< 2s per test) over budget. This asserts only the durable, static
    # invariant instead: `client.req.options[:retry]` is never Req's
    # implicit default (`nil`, today's actual bug) or either named preset —
    # it must be `false` (the interim S1 fix per spec §5 "pass retry: false
    # in the base Req options until S3 swaps in decide/2") or, after S3, the
    # `decide/2` function, neither of which is in this list. 400 is used for
    # the response-side check because it is retryable under neither Req's
    # `:safe_transient` preset (408/429/500/502/503/504 only) nor spec §5's
    # own default `http_statuses` (408, 429, 500..599), so this assertion
    # needs no retry loop — and no sleep — to observe. The response-side
    # match is loose (`{:error, _}`) so it survives S2. The transport-error
    # variant is dropped: unlike a fixed status, a stub that always answers
    # with a transport error cannot dodge S3's real backoff, and the static
    # invariant above already covers both failure kinds (it does not depend
    # on what the stub returns).
    test "B2: the client req never carries Req's built-in default retry" do
      assert {:ok, client} = StubAdapter.client(StubAdapter.respond(400, ~s({"models":[]})))

      refute client.req.options[:retry] in [nil, :safe_transient, :transient]
      assert {:error, _reason} = TypeSafe.list_models(client)
    end

    # Gate 4 review, PR #1, a935ea1: B3 (JS client.ts:318) — an explicit nil
    # model must fall back to client.default_model, same as an absent key.
    test "B3: system_one treats an explicit nil model as absent" do
      assert {:ok, client} =
               StubAdapter.client(
                 StubAdapter.respond(200, @system_one_response),
                 default_model: "client-default"
               )

      assert {:ok, _result} =
               TypeSafe.system_one(client, %{
                 state: "s",
                 questions: %{q1: TypeSafe.noul("?")},
                 model: nil
               })

      assert_received {:sent, request}

      assert {:ok, %{"model" => "client-default"}} =
               JSON.decode(IO.iodata_to_binary(request.body))
    end

    # Gate 4 review, PR #1, a935ea1: B5 (spec §4 L113) — option VALUES, not
    # only keys, must be guarded. Each of these raises today instead of
    # returning {:error, _}.
    test "B5: new/1 returns an error instead of raising for a wrong-typed option value" do
      invalid_opts = [
        [api_key: 123, get_env: fn _name -> nil end],
        [api_key: "k", base_url: 123, get_env: fn _name -> nil end],
        [api_key: "k", default_model: 42, get_env: fn _name -> nil end],
        [api_key: "k", req_options: nil, get_env: fn _name -> nil end],
        [api_key: "k", get_env: nil],
        [api_key: "k", default_headers: nil, get_env: fn _name -> nil end]
      ]

      for opts <- invalid_opts do
        assert {:error, %TypeSafe.Error{}} = TypeSafe.new(opts)
      end
    end

    # Gate 4 review, PR #1, a935ea1: B5, log_level — spec §2 L37 pins the
    # Elixir type as one of :debug/:info/:warning/:error/:off; nothing else
    # (an unknown atom, a boolean, or a string) is a valid option value.
    test "B5: new/1 returns an error instead of accepting an invalid log_level value" do
      for log_level <- [:bogus, true, "debug"] do
        assert {:error, %TypeSafe.Error{}} =
                 TypeSafe.new(api_key: "k", log_level: log_level, get_env: fn _name -> nil end)
      end
    end

    # Gate 4 review, PR #1, a935ea1: N2 — client.timeout must reach Req as
    # receive_timeout; today it is computed but never applied to any request.
    test "N2: the client's timeout is passed to Req as receive_timeout" do
      assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, ~s({"models":[]})))
      assert client.timeout == 10_000

      assert {:ok, []} = TypeSafe.list_models(client)
      assert_received {:sent, request}
      assert request.options[:receive_timeout] == 10_000
    end

    # Gate 4 review, PR #1, a935ea1: N4 — with_response must be value-checked
    # before any request is sent, not after (a bad value today still burns a
    # real request before crashing).
    test "N4: with_response with a non-boolean value errors before any request is sent" do
      assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))

      assert {:error, %TypeSafe.Error{}} =
               TypeSafe.system_one(
                 client,
                 %{state: "s", questions: %{q1: TypeSafe.noul("?")}},
                 with_response: "yes"
               )

      refute_received {:sent, _request}
    end

    # Gate 4 review, PR #1, a935ea1: N5 — a malformed request map must not
    # crash with FunctionClauseError; it is a caller error, not a bug.
    test "N5: a request map missing :state returns an error instead of raising" do
      assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))

      assert {:error, %TypeSafe.Error{}} =
               TypeSafe.system_one(client, %{questions: %{q1: TypeSafe.noul("?")}})

      refute_received {:sent, _request}
    end

    test "N5: a string-keyed request map returns an error instead of raising" do
      assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))

      assert {:error, %TypeSafe.Error{}} =
               TypeSafe.system_one(client, %{
                 "state" => "s",
                 "questions" => %{"q1" => %{"type" => "noul"}}
               })

      refute_received {:sent, _request}
    end

    # Gate 4 review, PR #1, a935ea1: N7 (spec §12 q16, operator decision) — an
    # explicit blank api_key must be rejected the same as a blank env value.
    test "N7: new/1 treats an explicit blank api_key the same as a blank env value" do
      for api_key <- ["", "   "] do
        assert {:error, %TypeSafe.Error{message: message}} =
                 TypeSafe.new(api_key: api_key, get_env: fn _name -> nil end)

        assert message =~ "TYPESAFE_API_KEY"
      end
    end

    # Gate 4 review, PR #1, a935ea1: N8 (spec §3 L62, JS client.ts:166-178) —
    # a nil header value deletes the header; it must never be sent.
    test "N8: a header with a nil value is not sent" do
      assert {:ok, client} =
               StubAdapter.client(
                 StubAdapter.respond(200, ~s({"models":[]})),
                 default_headers: %{"X-A" => nil}
               )

      assert {:ok, []} = TypeSafe.list_models(client)
      assert_received {:sent, request}
      assert Req.Request.get_header(request, "x-a") == []
    end

    # Gate 4 review, PR #1, 2467975 follow-up: N8, the per-call sibling — a
    # nil per-call header value must delete a header already set by
    # default_headers, not overwrite it with the empty string.
    test "N8: a per-call nil value deletes a header set by default_headers" do
      assert {:ok, client} =
               StubAdapter.client(
                 StubAdapter.respond(200, ~s({"models":[]})),
                 default_headers: %{"X-A" => "1"}
               )

      assert {:ok, []} = TypeSafe.list_models(client, headers: %{"x-a" => nil})
      assert_received {:sent, request}
      assert Req.Request.get_header(request, "x-a") == []
    end

    # Gate 4 review, PR #1, a935ea1: N12 (spec §3 "the port therefore sets
    # decode_body: false") — req_options must not be able to override the
    # SDK's own JSON decoding; a caller's decode_body: true is overridden,
    # not rejected, so the response still decodes correctly instead of
    # crashing in TypeSafe's own decode_body/1.
    test "N12: req_options cannot override decode_body; the response still decodes correctly" do
      assert {:ok, client} =
               StubAdapter.client(
                 StubAdapter.respond(200, ~s({"models":[]})),
                 req_options: [decode_body: true]
               )

      assert client.req.options[:decode_body] == false
      assert {:ok, []} = TypeSafe.list_models(client)
    end

    # Gate 4 review round 2 (approved a0e66bf, non-blocking): R1 — an
    # explicit nil option must fall back to env then default, matching JS
    # `fromCode ?? readEnv` (env.ts:22-23). Today `Config.validate_type`
    # calls `Keyword.fetch/2`, which finds the key present (even though its
    # value is nil) and runs the type guard on it directly, so nil is
    # treated as "given but wrong type" instead of "not given" — the
    # `nil ->` fallback clauses in resolve_api_key/resolve_string/
    # resolve_log_level are dead code today. This does not touch the B5
    # type guards: a genuinely wrong-typed value (`base_url: 123`) still
    # errors via the existing B5 test below, unaffected by this fix.
    test "R1: an explicit nil api_key falls back to env, then to the missing-key error" do
      env = %{"TYPESAFE_API_KEY" => "env-key"}

      assert {:ok, client} =
               StubAdapter.client(
                 StubAdapter.respond(200, ~s({"models":[]})),
                 api_key: nil,
                 get_env: fn name -> Map.get(env, name) end
               )

      assert {:ok, []} = TypeSafe.list_models(client)
      assert_received {:sent, request}
      assert Req.Request.get_header(request, "authorization") == ["Bearer env-key"]

      assert {:error, %TypeSafe.Error{message: message}} =
               TypeSafe.new(api_key: nil, get_env: fn _name -> nil end)

      assert message =~ "TYPESAFE_API_KEY"
    end

    test "R1: an explicit nil base_url falls back to env, then to the default" do
      env = %{"TYPESAFE_BASE_URL" => "https://env.test"}

      assert {:ok, client} =
               TypeSafe.new(
                 api_key: "k",
                 base_url: nil,
                 get_env: fn name -> Map.get(env, name) end
               )

      assert client.base_url == "https://env.test"

      assert {:ok, client} =
               TypeSafe.new(api_key: "k", base_url: nil, get_env: fn _name -> nil end)

      assert client.base_url == "https://api.typesafe.ai"
    end

    test "R1: an explicit nil default_model falls back to env, then to the default" do
      env = %{"TYPESAFE_DEFAULT_MODEL" => "env-model"}

      assert {:ok, client} =
               TypeSafe.new(
                 api_key: "k",
                 default_model: nil,
                 get_env: fn name -> Map.get(env, name) end
               )

      assert client.default_model == "env-model"

      assert {:ok, client} =
               TypeSafe.new(api_key: "k", default_model: nil, get_env: fn _name -> nil end)

      assert client.default_model == "jev-latest"
    end

    test "R1: an explicit nil log_level falls back to env, then to the default" do
      env = %{"TYPESAFE_LOG_LEVEL" => "debug"}

      assert {:ok, client} =
               TypeSafe.new(
                 api_key: "k",
                 log_level: nil,
                 get_env: fn name -> Map.get(env, name) end
               )

      assert client.log_level == :debug

      assert {:ok, client} =
               TypeSafe.new(api_key: "k", log_level: nil, get_env: fn _name -> nil end)

      assert client.log_level == :warning
    end

    # Gate 4 review round 2: R2 — req_options must not override SDK-owned
    # request settings. verified: today Keyword.merge/2 puts req_options
    # AFTER the base [base_url: base_url], so req_options wins for base_url;
    # client.base_url (the struct field) is computed from the ORIGINAL
    # base_url and does not agree with where the request actually goes.
    test "R2: req_options cannot override the client's base_url" do
      assert {:ok, client} =
               StubAdapter.client(
                 StubAdapter.respond(200, ~s({"models":[]})),
                 base_url: "https://x.test",
                 req_options: [base_url: "https://evil.test"]
               )

      assert client.base_url == "https://x.test"

      assert {:ok, []} = TypeSafe.list_models(client)
      assert_received {:sent, request}
      assert request.url.host == "x.test"
    end

    # R2, the auth sibling — verified: Req's built-in :auth request step
    # runs before the (stub) adapter, so a req_options auth: {:bearer, ...}
    # overwrites the authorization header we set at client-build time by
    # the time our own protected-header guarantees ever see the request.
    test "R2: req_options cannot override the configured Authorization header" do
      assert {:ok, client} =
               StubAdapter.client(
                 StubAdapter.respond(200, ~s({"models":[]})),
                 api_key: "secret",
                 req_options: [auth: {:bearer, "other"}]
               )

      assert {:ok, []} = TypeSafe.list_models(client)
      assert_received {:sent, request}
      assert Req.Request.get_header(request, "authorization") == ["Bearer secret"]
    end

    # R2, the timeout sibling — operator decision (recorded in docs/spec.md
    # §3): receive_timeout has its own future `:timeout` option (S3), so a
    # caller trying to set it via req_options is REJECTED at new/1 rather
    # than silently accepted-then-ignored. verified: today new/1 returns
    # {:ok, client} and client.req.options[:receive_timeout] == 1 — accepted,
    # even though the actual per-call receive_timeout: client.timeout always
    # wins at request time, so the value is dead weight at best.
    test "R2: req_options with receive_timeout is rejected, naming the option" do
      assert {:error, %TypeSafe.Error{message: message}} =
               TypeSafe.new(
                 api_key: "k",
                 req_options: [receive_timeout: 1],
                 get_env: fn _name -> nil end
               )

      assert message =~ "receive_timeout"
    end

    # Gate 4 review round 2: R3 — header containers/values are not
    # validated, unlike with_response. verified today: `default_headers: %{
    # "x" => %{a: 1}}` passes new/1 (is_map check only looks at the whole
    # map, not its values) and would raise on the first request; per-call
    # `headers: nil` and `headers: "x"` raise Protocol.UndefinedError
    # (Enumerable) inside build_request, before any HTTP call; a map header
    # value raises Protocol.UndefinedError (String.Chars); a list header
    # value is silently chardata-concatenated instead of rejected.
    test "R3: new/1 errors on a default_headers value that is not a valid header value" do
      assert {:error, %TypeSafe.Error{}} =
               TypeSafe.new(
                 api_key: "k",
                 default_headers: %{"x" => %{a: 1}},
                 get_env: fn _name -> nil end
               )
    end

    test "R3: a malformed per-call headers option errors before any request is sent" do
      assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))

      bad_headers = [nil, "x", %{"x" => %{a: 1}}, %{"x" => ["a", "b"]}]

      for headers <- bad_headers do
        assert {:error, %TypeSafe.Error{}} =
                 TypeSafe.system_one(
                   client,
                   %{state: "s", questions: %{q1: TypeSafe.noul("?")}},
                   headers: headers
                 )
      end

      refute_received {:sent, _request}
    end

    # Gate 4 review round 2: R4 — new/1's doc claims it "never raises on bad
    # input"; these three inputs still do (verified: FunctionClauseError in
    # Keyword.validate/2 for the first two, in Config.blank_to_nil/1 for the
    # third, since a working 1-arity get_env with a non-binary return value
    # passes the is_function(&1, 1) guard and only crashes once called).
    test "R4: new/1 returns an error instead of raising for non-keyword-list input" do
      assert {:error, %TypeSafe.Error{}} = TypeSafe.new(%{api_key: "k"})
      assert {:error, %TypeSafe.Error{}} = TypeSafe.new("k")
    end

    test "R4: new/1 returns an error instead of raising for a non-binary env value" do
      assert {:error, %TypeSafe.Error{}} =
               TypeSafe.new(api_key: "k", get_env: fn _name -> 123 end)
    end

    # Gate 4 review round 2: R5 — the fallback system_one/3 error names
    # `:state` as the required key even when :state is present and
    # :questions is the actual problem. verified: today's message is the
    # same static string for both cases below, literally containing the
    # substring "with a :state key" regardless of which key is wrong.
    test "R5: a request with :state but missing/invalid :questions names questions, not :state, as the problem" do
      assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))

      cases = [%{state: "s"}, %{state: "s", questions: [q: "bad"]}]

      for request <- cases do
        assert {:error, %TypeSafe.Error{message: message}} =
                 TypeSafe.system_one(client, request)

        refute message =~ "with a :state key"
        assert message =~ "questions"
      end
    end

    # R6 (Gate 4 review round 2) is already resolved as of 14d73d1: Config,
    # HTTP, and Questions all carry `@moduledoc false`, and no review/spec
    # citation (`Gate 4`, `N10`, `q12`, `q16`) remains in any public @doc or
    # @moduledoc text (grepped). This is a cheap verification, not a red
    # pin — it passes today and guards the fix against a future regression,
    # per the operator's explicit exception for this one finding.
    test "R6: internal modules are hidden from generated docs" do
      for mod <- [TypeSafe.Config, TypeSafe.HTTP, TypeSafe.Questions] do
        assert {:docs_v1, _anno, _lang, _format, :hidden, _meta, _docs} = Code.fetch_docs(mod)
      end
    end

    # Operator request (new, not a lettered finding): inspect/1 on a
    # %TypeSafe.RetryPolicy{} must not dump the ~100-element http_statuses
    # MapSet as raw, hash-ordered numbers. Pinned rendering (recorded in
    # docs/spec.md §4): a custom Inspect implementation keeps all nine
    # fields visible and renders http_statuses as a compact summary
    # containing "408", "429", and "500..599" — the intended reading is
    # that the default set is exactly {408, 429} ∪ 500..599, and nothing
    # else. verified today: the derived struct inspect is 620 characters
    # and enumerates individual members in hash order (e.g. "545, 533,
    # 597, 500, ...") with no range notation. Operator decision (Gate 4
    # follow-up on 6701bd5): the length bound is 300, not 200 — a full
    # nine-field labelled rendering with the compact http_statuses summary
    # measures ~248 chars (field names alone are 144), so 200 was
    # unreachable without hiding a field nobody asked to hide.
    test "inspect(%TypeSafe.RetryPolicy{}) renders http_statuses compactly, not as a number dump" do
      rendered = inspect(%TypeSafe.RetryPolicy{})

      assert String.length(rendered) < 300
      assert rendered =~ "408"
      assert rendered =~ "429"
      assert rendered =~ "500..599"
    end

    # Same fix, checked through the client: RetryPolicy is a nested field
    # of TypeSafe.Client, so a correct Inspect implementation renders
    # compactly there too. "545" is one of the hash-ordered individual
    # members visible in today's raw dump (verified above); its absence
    # here distinguishes a real fix from one that only patches the
    # standalone %TypeSafe.RetryPolicy{} case.
    test "inspect(client) also stays free of the http_statuses number dump" do
      assert {:ok, client} = TypeSafe.new(api_key: "k", get_env: fn _name -> nil end)

      rendered = inspect(client)

      refute rendered =~ "545"
      assert rendered =~ "500..599"
    end

    # Gate 4 review round 3, D3 (non-blocking): TypeSafe.HTTP.decode_body/1
    # has no clause for a body that isn't nil/""/binary, so it raises
    # FunctionClauseError. Unreachable through Req's own pipeline — the SDK
    # forces decode_body: false, so Req itself never hands back a decoded
    # term — but directly reachable when a caller injects a custom adapter
    # via req_options: [adapter: ...] that returns an already-decoded body,
    # exactly what a consumer integrating against our stub-style adapter
    # will do. Per docs/spec.md §3 ("decode_body is SDK-owned"): the
    # already-decoded term is exactly what decode_body/1 would otherwise
    # have produced from JSON text, so it is passed through unchanged, not
    # re-encoded or rejected.
    test "D3: a response body that is already decoded is passed through, not re-decoded" do
      assert {:ok, client} =
               StubAdapter.client(StubAdapter.respond(200, %{"models" => []}))

      assert {:ok, []} = TypeSafe.list_models(client)
    end
  end
end
