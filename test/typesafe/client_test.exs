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
        assert {:error, %TypeSafe.Error{}} = TypeSafe.list_models(client)
      end
    end

    # Gate 4 review, PR #1, a935ea1: B1, the "models" key present but not a list.
    test "B1: list_models errors when \"models\" is present but not a list" do
      bodies = [~s({"models":"bad"}), ~s({"models":null})]

      for body <- bodies do
        assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, body))
        assert {:error, %TypeSafe.Error{}} = TypeSafe.list_models(client)
      end
    end

    # Gate 4 review, PR #1, a935ea1: B2 (spec §5 L154) — a 503 must not be
    # silently retried by Req's default `:safe_transient` policy. Proven fast:
    # the stub answers 503 then 200; a fixed client never reaches the second
    # response (1 call, immediate error). Today's hidden retry reaches it
    # after one real backoff delay and returns {:ok, _}, failing this assertion.
    test "B2: a GET answered 503 hits the adapter exactly once" do
      {:ok, agent} = start_supervised({Agent, fn -> [503, 200] end})
      test_pid = self()

      stub = fn request ->
        status =
          Agent.get_and_update(agent, fn
            [next] -> {next, [next]}
            [next | rest] -> {next, rest}
          end)

        send(test_pid, {:sent, request})

        {request,
         Req.Response.new(
           status: status,
           headers: [{"content-type", "application/json"}],
           body: ~s({"models":[]})
         )}
      end

      assert {:ok, client} = StubAdapter.client(stub)

      assert {:error, %TypeSafe.Error{}} = TypeSafe.list_models(client)

      assert_received {:sent, _request}
      refute_received {:sent, _request}
    end

    # Gate 4 review, PR #1, a935ea1: B2, the transport-error sibling — Req's
    # default retry also covers `:closed`/similar reasons, not only statuses.
    test "B2: a GET answered with a transport error hits the adapter exactly once" do
      {:ok, agent} = start_supervised({Agent, fn -> [:error, :ok] end})
      test_pid = self()

      stub = fn request ->
        outcome =
          Agent.get_and_update(agent, fn
            [next] -> {next, [next]}
            [next | rest] -> {next, rest}
          end)

        send(test_pid, {:sent, request})

        case outcome do
          :error ->
            {request, Req.TransportError.exception(reason: :closed)}

          :ok ->
            {request,
             Req.Response.new(
               status: 200,
               headers: [{"content-type", "application/json"}],
               body: ~s({"models":[]})
             )}
        end
      end

      assert {:ok, client} = StubAdapter.client(stub)

      assert {:error, %TypeSafe.Error{}} = TypeSafe.list_models(client)

      assert_received {:sent, _request}
      refute_received {:sent, _request}
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

      assert {:ok, []} = TypeSafe.list_models(client)
    end
  end
end
