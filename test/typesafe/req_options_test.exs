defmodule TypeSafe.ReqOptionsTest do
  use ExUnit.Case, async: true

  # Issue #7: `req_options` is a transport allowlist, checked in `TypeSafe.new/1`
  # against the view Req resolves (last-wins). Every rejection is a
  # `{:error, %TypeSafe.Error{}}`; nothing here may raise.
  #
  # These tests read `Req.default_options/0` implicitly (through `new/1`) and
  # assume it is empty. The module that sets it lives in
  # test/typesafe/req_default_options_test.exs and runs `async: false`, so ExUnit
  # never overlaps it with this module.

  alias TypeSafe.Error
  alias TypeSafe.StubAdapter

  @ok_body ~s({"models":[]})

  @supported "adapter, connect_options, finch, finch_private, headers, inet6, unix_socket"
  @headers_message "req_options headers must be a map or a list of {name, value} pairs"
  @finch_shape_message "req_options finch must be a keyword list"

  # One entry per allowed top-level key (headers has two shapes).
  @allowed [
    [adapter: StubAdapter],
    [finch: [size: 2]],
    [connect_options: [timeout: 300]],
    [inet6: true],
    [unix_socket: "/tmp/ts.sock"],
    [finch_private: %{a: 1}],
    [headers: [{"x-a", "1"}]],
    [headers: %{"x-a" => "1"}]
  ]

  # Accepted and overridden by the SDK (existing behavior).
  @overridden [
    [base_url: "https://other.test"],
    [decode_body: true],
    [retry: :transient],
    [auth: {:bearer, "other"}]
  ]

  @allowed_keys [
    :adapter,
    :finch,
    :connect_options,
    :inet6,
    :unix_socket,
    :finch_private,
    :headers
  ]
  @overridden_keys [:base_url, :decode_body, :retry, :auth]

  @finch_pool_keys [
    :size,
    :count,
    :protocols,
    :conn_opts,
    :pool_max_idle_time,
    :conn_max_idle_time,
    :start_pool_metrics?,
    :http2
  ]
  @finch_keys [:name, :pool_timeout, :pool_tag] ++ @finch_pool_keys
  @connect_keys [
    :timeout,
    :protocols,
    :transport_opts,
    :proxy,
    :proxy_headers,
    :hostname,
    :client_settings
  ]

  defp new(req_options) do
    TypeSafe.new(api_key: "k", get_env: fn _name -> nil end, req_options: req_options)
  end

  defp unsupported(key),
    do: "req_options does not support #{key}; supported keys are #{@supported}"

  defp drain_sent(acc \\ []) do
    receive do
      {:sent, request} -> drain_sent([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp reaches_req?(req, {:adapter, adapter}), do: req.adapter == adapter
  defp reaches_req?(req, {:headers, _headers}), do: Req.Request.get_header(req, "x-a") == ["1"]
  defp reaches_req?(req, {key, value}), do: req.options[key] == value

  describe "accepted input" do
    test "an empty list is accepted and resolves to only the SDK-owned keys" do
      assert {:ok, client} = new([])
      assert client.req.options |> Map.keys() |> Enum.sort() == [:base_url, :decode_body, :retry]
    end

    test "each allowed key is accepted and its value reaches the Req struct" do
      for [entry] = row <- @allowed do
        assert {:ok, %TypeSafe.Client{req: req}} = new(row)
        assert reaches_req?(req, entry), "#{inspect(row)} did not reach the Req struct"
      end
    end

    test "every finch sub-key on its own is accepted, whatever its value" do
      for key <- @finch_keys do
        assert {:ok, %TypeSafe.Client{}} = new(finch: [{key, 1}]), "finch: [#{key}: 1]"
      end
    end

    test "every connect_options sub-key is accepted, whatever its value" do
      for key <- @connect_keys do
        assert {:ok, %TypeSafe.Client{}} = new(connect_options: [{key, 1}]),
               "connect_options: [#{key}: 1]"
      end
    end

    test "headers accepts a map, and a list of pairs with binary or atom names" do
      assert {:ok, %TypeSafe.Client{}} = new(headers: %{"x-a" => "1"})
      assert {:ok, %TypeSafe.Client{}} = new(headers: [{"x-a", "1"}, {:"x-b", "2"}])
      assert {:ok, %TypeSafe.Client{}} = new(headers: [])
    end

    test "each overridden key is still accepted" do
      for row <- @overridden do
        assert {:ok, %TypeSafe.Client{}} = new(row), inspect(row)
      end
    end

    # Control: `size:` is a pool key Finch 0.24 understands, so the allowlist
    # must keep it working through a real pool, not only at new/1.
    test "a real Finch call with finch: [size: 2] returns a Connection error and does not raise" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(listener)
      :ok = :gen_tcp.close(listener)

      assert {:ok, client} =
               TypeSafe.new(
                 api_key: "k",
                 base_url: "http://127.0.0.1:#{port}",
                 retry: [max_retries: 0],
                 get_env: fn _name -> nil end,
                 req_options: [finch: [size: 2]]
               )

      assert {:error, %Error.Connection{}} = TypeSafe.list_models(client)
    end
  end

  describe "rejected input" do
    test "an unknown top-level key is rejected by name and never raises" do
      assert {:error, %Error{message: message}} = new(bogus: 1)
      assert message == unsupported("bogus")
    end

    test "http_errors is rejected, so a non-2xx response cannot make a call raise" do
      assert {:error, %Error{message: message}} = new(http_errors: :raise)
      assert message == unsupported("http_errors")
    end

    test "each Req option that could change what the SDK sends is rejected by name" do
      values = %{
        url: "http://u:p@host",
        aws_sigv4: [access_key_id: "a", secret_access_key: "s"],
        redirect_trusted: true,
        location_trusted: true,
        json: %{a: 1},
        form: [a: 1],
        body: "x",
        into: :self,
        plug: {Plug.Test, []},
        plugins: [:x],
        method: :post,
        raw: true,
        checksum: :md5,
        cache: true,
        compress_body: true,
        params: [a: 1],
        redirect: true
      }

      for {key, value} <- values do
        assert {:error, %Error{message: message}} = new([{key, value}]), "#{key} was accepted"
        assert message == unsupported(key)
      end
    end

    test "size, pool_size and start_pool_metrics? are finch keys, so they are rejected at the top level" do
      for key <- [:size, :pool_size, :start_pool_metrics?, :pool_timeout] do
        assert {:error, %Error{message: message}} = new([{key, 1}])
        assert message == unsupported(key)
      end
    end

    test "an unknown finch sub-key is rejected; pool_size is not a Finch key (size is)" do
      for row <- [[pool_size: 2], [size: 2, bogus: 1], [pool_timeout: 1, http3: true]] do
        assert {:error, %Error{message: message}} = new(finch: row)
        [key | _rest] = Enum.reject(Keyword.keys(row), &(&1 in @finch_keys))
        assert message == "req_options does not support finch: [#{key}: ...]"
      end
    end

    test "an unknown connect_options sub-key is rejected" do
      assert {:error, %Error{message: message}} = new(connect_options: [bogus: 1])
      assert message == "req_options does not support connect_options: [bogus: ...]"

      assert {:error, %Error{message: message}} = new(connect_options: [timeout: 1, pool_size: 2])
      assert message == "req_options does not support connect_options: [pool_size: ...]"
    end

    test "finch given as an atom name is rejected as not a keyword list" do
      assert {:error, %Error{message: @finch_shape_message}} = new(finch: :unregistered_name)
      assert {:error, %Error{message: @finch_shape_message}} = new(finch: Req.Finch)
    end

    test "finch given as another non-list is still rejected with the same message" do
      assert {:error, %Error{message: @finch_shape_message}} = new(finch: 5)
    end

    test "finch: [name: ...] with a pool key is rejected, naming the first pool key given" do
      for key <- @finch_pool_keys do
        assert {:error, %Error{message: message}} = new(finch: [{:name, :my_finch}, {key, 1}])

        assert message ==
                 "req_options must not set finch: [name: ...] together with finch: [#{key}: ...]"
      end

      assert {:error, %Error{message: message}} = new(finch: [name: :my_finch, count: 1, size: 2])
      assert message =~ "together with finch: [count: ...]"

      assert {:error, %Error{message: message}} = new(finch: [size: 2, count: 1, name: :my_finch])
      assert message =~ "together with finch: [size: ...]"
    end

    test "finch: [name: ...] with pool_timeout or pool_tag is accepted" do
      assert {:ok, %TypeSafe.Client{}} = new(finch: [name: :my_finch, pool_timeout: 1])
      assert {:ok, %TypeSafe.Client{}} = new(finch: [name: :my_finch, pool_tag: :t])

      assert {:ok, %TypeSafe.Client{}} =
               new(finch: [name: :my_finch, pool_timeout: 1, pool_tag: :t])
    end

    test "finch: [name: Req.Finch, pool_size: 2] fails the sub-key check before the name check" do
      assert {:error, %Error{message: message}} = new(finch: [name: Req.Finch, pool_size: 2])
      assert message == "req_options does not support finch: [pool_size: ...]"
    end

    test "headers that are not a map or a list of {name, value} pairs are rejected" do
      for bad <- [:bad, "x-a: 1", 5, [1], [{1, "v"}], [{"a", "b", "c"}], [{"a", "b"}, :x]] do
        assert {:error, %Error{message: @headers_message}} = new(headers: bad), inspect(bad)
      end
    end
  end

  describe "last-wins on repeated keys (the view Req resolves)" do
    test "a later finch without name overrides an earlier one with name and a pool key" do
      assert {:ok, client} = new(finch: [name: :my_finch, size: 2], finch: [size: 3])
      assert client.req.options[:finch] == [size: 3]
    end

    test "the reverse order leaves name with a pool key, which is rejected" do
      assert {:error, %Error{message: message}} =
               new(finch: [size: 3], finch: [name: :my_finch, size: 2])

      assert message ==
               "req_options must not set finch: [name: ...] together with finch: [size: ...]"
    end

    test "an unknown key in an overridden earlier entry is not an error" do
      assert {:ok, client} = new(finch: [bogus: 1], finch: [size: 2])
      assert client.req.options[:finch] == [size: 2]
    end

    test "an unknown key in the kept entry is an error" do
      assert {:error, %Error{message: "req_options does not support finch: [bogus: ...]"}} =
               new(finch: [size: 2], finch: [bogus: 1])
    end

    test "a repeated headers key is judged by its last value" do
      assert {:ok, %TypeSafe.Client{}} = new(headers: :bad, headers: %{"x-a" => "1"})

      assert {:error, %Error{message: @headers_message}} =
               new(headers: %{"x-a" => "1"}, headers: :bad)
    end
  end

  describe "check order" do
    test "the keyword-list type check comes first" do
      assert {:error, %Error{message: "req_options must be a keyword list"}} = new([1])
    end

    test "the five named keys come before the finch shape" do
      assert {:error, %Error{message: message}} = new(finch: :a, retry_delay: 1)
      assert message == "req_options must not set retry_delay; use the retry option instead"
    end

    test "finch timeouts come before the top-level allowlist" do
      assert {:error, %Error{message: message}} = new(bogus: 1, finch: [receive_timeout: 5])

      assert message ==
               "req_options must not set finch: [receive_timeout: ...]; " <>
                 "use the client's own timeout option instead"
    end

    test "the finch and connect_options pair comes before the top-level allowlist" do
      assert {:error, %Error{message: message}} =
               new(finch: [size: 2], connect_options: [timeout: 1], bogus: 1)

      assert message ==
               "req_options must not set both finch and connect_options; " <>
                 "Req accepts only one of them"
    end

    test "the top-level allowlist comes before the finch sub-key check" do
      assert {:error, %Error{message: message}} = new(bogus: 1, finch: [bogus: 2])
      assert message == unsupported("bogus")
    end

    test "the finch sub-key check comes before name with a pool key" do
      assert {:error, %Error{message: message}} = new(finch: [name: :my_finch, size: 2, bogus: 1])
      assert message == "req_options does not support finch: [bogus: ...]"
    end

    test "the finch sub-key check comes before the headers shape" do
      assert {:error, %Error{message: message}} = new(finch: [bogus: 1], headers: :bad)
      assert message == "req_options does not support finch: [bogus: ...]"
    end

    test "name with a pool key comes before the headers shape" do
      assert {:error, %Error{message: message}} =
               new(finch: [name: :my_finch, size: 2], headers: :bad)

      assert message =~ "together with finch: [size: ...]"
    end
  end

  describe "fail-closed against Req options" do
    @sample_values %{
      finch: [size: 2],
      connect_options: [timeout: 300],
      headers: [{"x-a", "1"}],
      adapter: StubAdapter,
      inet6: true,
      unix_socket: "/tmp/ts.sock",
      finch_private: %{a: 1},
      base_url: "https://other.test",
      decode_body: true,
      retry: :transient,
      auth: {:bearer, "other"},
      url: "http://u:p@host",
      method: :post,
      body: "x",
      json: %{a: 1},
      form: [a: 1],
      params: [a: 1],
      into: :self,
      plugins: [:x],
      plug: {Plug.Test, []},
      aws_sigv4: [access_key_id: "a", secret_access_key: "s"]
    }

    test "new/1 never raises and accepts a Req option only if it is on the allowlist" do
      extra = [:method, :url, :headers, :body, :adapter, :into, :plugins]
      keys = Enum.uniq(Enum.to_list(Req.new().registered_options) ++ extra)
      permitted = @allowed_keys ++ @overridden_keys

      failures =
        for key <- keys,
            value = Map.get(@sample_values, key, true),
            outcome = outcome(key, value),
            outcome != expected_outcome(key, permitted) do
          {key, outcome}
        end

      assert failures == []
    end

    defp outcome(key, value) do
      case new([{key, value}]) do
        {:ok, %TypeSafe.Client{}} -> :accepted
        {:error, %Error{}} -> :rejected
      end
    rescue
      exception -> {:raised, exception.__struct__}
    end

    defp expected_outcome(key, permitted),
      do: if(key in permitted, do: :accepted, else: :rejected)
  end

  describe "the SDK still owns the wire" do
    test "the bearer key is sent with each allowed req_options entry" do
      for row <- @allowed do
        {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @ok_body), req_options: row)

        assert {:ok, []} = TypeSafe.list_models(client)
        assert [request] = drain_sent()
        assert Req.Request.get_header(request, "authorization") == ["Bearer k"], inspect(row)
      end
    end

    test "a caller authorization header is replaced by the SDK's bearer key" do
      {:ok, client} =
        StubAdapter.client(StubAdapter.respond(200, @ok_body),
          req_options: [headers: [{"authorization", "Bearer evil"}]]
        )

      assert {:ok, []} = TypeSafe.list_models(client)
      assert [request] = drain_sent()
      assert Req.Request.get_header(request, "authorization") == ["Bearer k"]
    end

    test "the resolved Req struct holds only allowed and SDK-owned keys, and no body, into, or auth" do
      permitted = @allowed_keys ++ @overridden_keys
      rows = for a <- @allowed, b <- @allowed ++ @overridden ++ [[]], do: a ++ b

      accepted =
        for row <- rows, {:ok, %TypeSafe.Client{req: req}} <- [new(row)] do
          assert Enum.all?(Map.keys(req.options), &(&1 in permitted)), inspect(row)
          assert req.options[:auth] == nil, inspect(row)
          assert req.body == nil, inspect(row)
          assert req.into == nil, inspect(row)

          finch = req.options[:finch] || []
          refute Keyword.has_key?(finch, :receive_timeout), inspect(row)
          refute Keyword.has_key?(finch, :request_timeout), inspect(row)
          row
        end

      assert accepted != []
    end
  end
end
