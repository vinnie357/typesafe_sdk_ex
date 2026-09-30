defmodule TypeSafe.ReqDefaultOptionsTest do
  # async: false. Shared state: `Req.default_options/0` reads the global
  # Application env `:req, :default_options`, and Req has no per-call injection
  # for it, so a test can only set it process-wide. ExUnit runs this module alone
  # (after every async module), and setup/on_exit restore the previous value.
  use ExUnit.Case, async: false

  alias TypeSafe.Error
  alias TypeSafe.StubAdapter

  @ok_body ~s({"models":[]})
  @source "config :req, :default_options"
  @supported "adapter, connect_options, finch, finch_private, headers, inet6, unix_socket"
  @timeout_hint "use the client's own timeout option instead"

  setup do
    previous = Application.fetch_env(:req, :default_options)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:req, :default_options, value)
        :error -> Application.delete_env(:req, :default_options)
      end
    end)

    :ok
  end

  defp put_defaults(defaults), do: Application.put_env(:req, :default_options, defaults)

  defp new(req_options \\ []) do
    TypeSafe.new(api_key: "k", get_env: fn _name -> nil end, req_options: req_options)
  end

  defp drain_sent(acc \\ []) do
    receive do
      {:sent, request} -> drain_sent([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the allowlist applies to config :req, :default_options" do
    test "a disallowed default is rejected, naming config :req, :default_options" do
      cases = [
        {[finch: [receive_timeout: 5]],
         "#{@source} must not set finch: [receive_timeout: ...]; #{@timeout_hint}"},
        {[request_timeout: 5], "#{@source} must not set request_timeout; #{@timeout_hint}"},
        {[retry_delay: 1], "#{@source} must not set retry_delay; use the retry option instead"},
        {[http_errors: :raise],
         "#{@source} does not support http_errors; supported keys are #{@supported}"},
        {[bogus: 1], "#{@source} does not support bogus; supported keys are #{@supported}"},
        {[plugins: [:x]],
         "#{@source} does not support plugins; supported keys are #{@supported}"},
        {[finch: [bogus: 1]], "#{@source} does not support finch: [bogus: ...]"},
        {[finch: [pool_size: 2]], "#{@source} does not support finch: [pool_size: ...]"},
        {[connect_options: [bogus: 1]],
         "#{@source} does not support connect_options: [bogus: ...]"},
        {[finch: :some_name], "#{@source} finch must be a keyword list"},
        {[finch: [name: :my_finch, size: 2]],
         "#{@source} must not set finch: [name: ...] together with finch: [size: ...]"},
        {[headers: :bad], "#{@source} headers must be a map or a list of {name, value} pairs"}
      ]

      for {defaults, expected} <- cases do
        put_defaults(defaults)

        assert {:error, %Error{message: message}} = new()
        assert message == expected, "defaults #{inspect(defaults)}"
      end
    end

    test "a default header value that is not a binary or list of binaries names the config" do
      put_defaults(headers: [{"a", %{}}])

      assert {:error, %Error{message: message}} = new()
      assert message == "#{@source} headers must be a map or a list of {name, value} pairs"
    end

    test "the source is still config :req, :default_options when req_options sets other keys" do
      put_defaults(bogus: 1)

      assert {:error, %Error{message: message}} = new(adapter: StubAdapter)
      assert message == "#{@source} does not support bogus; supported keys are #{@supported}"
    end

    test "allowed defaults are accepted" do
      put_defaults(connect_options: [timeout: 300], inet6: true)

      assert {:ok, client} = new()
      assert client.req.options[:connect_options] == [timeout: 300]
      assert client.req.options[:inet6] == true
    end
  end

  describe "the SDK still owns auth, base_url, decode_body and retry" do
    test "a default auth is accepted and the SDK's bearer key is still what is sent" do
      put_defaults(auth: {:bearer, "evil"})

      {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @ok_body))

      assert {:ok, []} = TypeSafe.list_models(client)
      assert [request] = drain_sent()
      assert Req.Request.get_header(request, "authorization") == ["Bearer k"]
    end

    test "default base_url, decode_body and retry are accepted and overridden by the SDK" do
      put_defaults(base_url: "http://x", decode_body: true, retry: :transient)

      assert {:ok, client} = new()
      assert client.req.options[:base_url] == "https://api.typesafe.ai"
      assert client.req.options[:decode_body] == false
      assert client.req.options[:retry] == false
    end
  end

  describe "req_options wins over config :req, :default_options" do
    test "a req_options finch replaces a default finch, so the default is not checked" do
      put_defaults(finch: [receive_timeout: 5])

      assert {:ok, client} = new(finch: [size: 2])
      assert client.req.options[:finch] == [size: 2]
    end

    test "a bad key present in req_options names req_options, not the config" do
      put_defaults(bogus: 1)

      assert {:error, %Error{message: message}} = new(bogus: 2)
      assert message == "req_options does not support bogus; supported keys are #{@supported}"
    end

    test "a bad default is masked by a valid req_options value for the same key" do
      put_defaults(headers: :bad)

      assert {:ok, %TypeSafe.Client{}} = new(headers: %{"x-a" => "1"})
    end
  end

  describe "the shape of config :req, :default_options" do
    test "defaults that are not a keyword list are rejected and never raise" do
      for bad <- [%{finch: []}, [:a], [{:finch, []} | :tail], "x"] do
        put_defaults(bad)

        assert {:error, %Error{message: message}} = new()
        assert message == "#{@source} must be a keyword list", inspect(bad)
      end
    end

    test "a default connect_options that is not a keyword list names the config" do
      for bad <- [5, :x, %{timeout: 1}, [1], [{"a", 1}], [{:timeout, 1} | :tail]] do
        put_defaults(connect_options: bad)

        assert {:error, %Error{message: message}} = new()
        assert message == "#{@source} connect_options must be a keyword list", inspect(bad)
      end
    end
  end

  describe "repeated default headers entries (Req folds every one)" do
    @headers_error "#{@source} headers must be a map or a list of {name, value} pairs"

    test "a bad entry is rejected whichever position it has" do
      bad = [{"a", %{}}]
      good = [{"b", "c"}]

      for defaults <- [[headers: bad, headers: good], [headers: good, headers: bad]] do
        put_defaults(defaults)

        assert {:error, %Error{message: @headers_error}} = new(), inspect(defaults)
      end
    end

    test "good entries are accepted and Req sends both headers" do
      put_defaults(headers: [{"a", "1"}], headers: [{"b", "2"}])

      {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @ok_body))

      assert {:ok, []} = TypeSafe.list_models(client)
      assert [request] = drain_sent()
      assert Req.Request.get_header(request, "a") == ["1"]
      assert Req.Request.get_header(request, "b") == ["2"]
    end

    test "req_options headers replace every default headers entry, so bad defaults are not checked" do
      put_defaults(headers: [{"a", %{}}], headers: [{"b", "c"}])

      assert {:ok, %TypeSafe.Client{}} = new(headers: [{"x", "y"}])
    end
  end

  describe "finch and connect_options from different sources" do
    @pair_message "req_options and config :req, :default_options must not set both " <>
                    "finch and connect_options; Req accepts only one of them"

    test "a default finch with a req_options connect_options names both sources" do
      put_defaults(finch: [size: 2])

      assert {:error, %Error{message: @pair_message}} = new(connect_options: [timeout: 1])
    end

    test "a default connect_options with a req_options finch names both sources" do
      put_defaults(connect_options: [timeout: 1])

      assert {:error, %Error{message: @pair_message}} = new(finch: [size: 2])
    end

    test "both keys from the defaults keep the single-source config message" do
      put_defaults(finch: [size: 2], connect_options: [timeout: 1])

      assert {:error, %Error{message: message}} = new()

      assert message ==
               "#{@source} must not set both finch and connect_options; " <>
                 "Req accepts only one of them"
    end
  end
end
