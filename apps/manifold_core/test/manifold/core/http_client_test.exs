defmodule Manifold.Core.HTTPClientTest do
  use ExUnit.Case, async: false
  alias Manifold.Core.HTTPClient
  alias HTTPClient.{Response, TransportError}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:http_fetch)
    :ok
  end

  setup do
    HTTPClient.Test.verify_on_exit!()
  end

  defp server(fun) do
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 3_000)

        try do
          fun.(socket, listener, parent)
        after
          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        end
      end)

    {"http://127.0.0.1:#{port}/wire", task}
  end

  defp read_request(socket, acc \\ "") do
    if String.contains?(acc, "\r\n\r\n") do
      [head, body] = String.split(acc, "\r\n\r\n", parts: 2)

      length =
        case Regex.run(~r/content-length: ([0-9]+)/i, head) do
          [_, length] -> String.to_integer(length)
          _ -> 0
        end

      if byte_size(body) >= length, do: {head, body}, else: receive_request(socket, acc)
    else
      receive_request(socket, acc)
    end
  end

  defp receive_request(socket, acc) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 3_000)
    read_request(socket, acc <> data)
  end

  defp response(socket, body, extra \\ "") do
    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: #{byte_size(body)}\r\n",
      extra,
      "\r\n",
      body
    ])
  end

  test "form and auth bytes cross native Fetch, request telemetry is silent" do
    owner = self()

    :ok =
      :telemetry.attach_many(
        "manifold-http-client-secrets",
        [
          [:http_fetch, :request, :start],
          [:http_fetch, :request, :stop],
          [:http_fetch, :request, :exception],
          [:http_fetch, :streaming, :start],
          [:http_fetch, :streaming, :chunk],
          [:http_fetch, :streaming, :stop]
        ],
        fn event, _, metadata, _ -> send(owner, {:telemetry, event, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach("manifold-http-client-secrets") end)

    {url, task} =
      server(fn socket, _, parent ->
        {head, body} = read_request(socket)
        send(parent, {:wire, head, body})

        response(
          socket,
          ~s({"ok":true}),
          "Content-Type: application/json\r\nX-Repeated: one\r\nX-Repeated: two\r\n"
        )
      end)

    assert {:ok, %Response{status: 200, body: %{"ok" => true}} = result} =
             HTTPClient.post(
               url: url,
               form: [token: "a b&c"],
               auth: {:bearer, "FAKE_BEARER"},
               headers: [{"cookie", "FAKE_COOKIE"}, {"x-manifold-signature", "FAKE_SIGNATURE"}],
               params: [nonce: "FAKE_QUERY"]
             )

    assert Response.get_header(result, "X-Repeated") == ["one", "two"]
    assert_receive {:wire, head, "token=a+b%26c"}
    assert head =~ "FAKE_BEARER"
    assert head =~ "FAKE_COOKIE"
    assert head =~ "nonce=FAKE_QUERY"
    refute_receive {:telemetry, _, _}, 20
    Task.await(task)
  end

  test "raw compressed bytes stay exact despite JSON media type" do
    body = :zlib.gzip(~s({"ok":true}))

    {url, task} =
      server(fn s, _, _ ->
        read_request(s)
        response(s, body, "Content-Encoding: gzip\r\nContent-Type: application/json\r\n")
      end)

    assert {:ok, %Response{body: ^body, private: %{raw_body_size: size}}} =
             HTTPClient.request(url: url, decode_body: false)

    assert size == byte_size(body)
    Task.await(task)
  end

  test "prefix retention preserves full byte count" do
    body = String.duplicate("x", 130_000)

    {url, task} =
      server(fn s, _, _ ->
        read_request(s)
        response(s, body)
      end)

    assert {:ok, %Response{body: retained, private: %{raw_body_size: 130_000}}} =
             HTTPClient.request(url: url, retain_body_bytes: 65_536)

    assert byte_size(retained) == 65_536
    assert retained == String.duplicate("x", 65_536)
    Task.await(task)
  end

  test "hard body bound cancels request and closes the peer" do
    {url, task} =
      server(fn s, _, p ->
        read_request(s)
        :gen_tcp.send(s, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n8\r\n12345678\r\n")
        send(p, {:peer_closed, :gen_tcp.recv(s, 0, 3_000)})
      end)

    assert {:error, %TransportError{reason: :response_limit}} =
             HTTPClient.request(url: url, max_body_bytes: 4)

    assert_receive {:peer_closed, {:error, :closed}}, 1_000
    Task.await(task)
  end

  test "lazy response stopping after first chunk cancels remaining transfer" do
    {url, task} =
      server(fn s, _, p ->
        read_request(s)
        :gen_tcp.send(s, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\none\r\n")
        send(p, {:peer_closed, :gen_tcp.recv(s, 0, 3_000)})
      end)

    assert {:ok, %Response{body: stream, private: %{streaming: true}}} =
             HTTPClient.request(url: url, stream_response: true)

    assert Enum.take(stream, 1) == ["one"]
    assert_receive {:peer_closed, {:error, :closed}}, 1_000
    Task.await(task)
  end

  test "stream truncation propagates a safe failure" do
    {url, task} =
      server(fn s, _, _ ->
        read_request(s)
        :gen_tcp.send(s, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nxx")
      end)

    assert {:error, %TransportError{reason: reason}} = HTTPClient.request(url: url)
    assert reason in [:closed, :content_length_mismatch, :transport_failure]
    Task.await(task)
  end

  test "deadline closes peer and never replays a submitted POST" do
    {url, task} =
      server(fn s, listener, p ->
        assert {_, "sent"} = read_request(s)
        send(p, {:peer_closed, :gen_tcp.recv(s, 0, 3_000)})
        send(p, {:second_attempt, :gen_tcp.accept(listener, 100)})
      end)

    assert {:error, %TransportError{phase: :unknown, reason: reason}} =
             HTTPClient.post(url: url, body: "sent", receive_timeout: 100)

    assert reason in [:request_timeout, :timeout]
    assert_receive {:peer_closed, {:error, :closed}}, 1_000
    assert_receive {:second_attempt, {:error, :timeout}}, 1_000
    Task.await(task)
  end

  test "pre-send evidence is restricted to native confirmed TCP failure" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)

    assert {:error, %TransportError{phase: :pre_transmission, reason: :econnrefused}} =
             HTTPClient.post(url: "http://127.0.0.1:#{port}/", body: "sent")
  end

  test "manual redirect response never forwards credentials" do
    {url, task} =
      server(fn s, listener, p ->
        read_request(s)

        :gen_tcp.send(
          s,
          "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )

        send(p, {:second_attempt, :gen_tcp.accept(listener, 100)})
      end)

    assert {:ok, %Response{status: 302, body: ""}} =
             HTTPClient.request(url: url, auth: {:bearer, "FAKE_TOKEN"})

    assert_receive {:second_attempt, {:error, :timeout}}, 1_000
    Task.await(task)
  end

  test "test expectations are owned, visible to Tasks and explicitly allowed processes" do
    owner = self()

    HTTPClient.Test.expect(__MODULE__, 2, fn conn ->
      {:ok, "encoded", conn} = Plug.Conn.read_body(conn)
      HTTPClient.Test.json(conn, %{path: conn.request_path})
    end)

    task =
      Task.async(fn ->
        HTTPClient.post(
          url: "http://test/one",
          body: "encoded",
          plug: {HTTPClient.Test, __MODULE__}
        )
      end)

    assert {:ok, %Response{body: %{"path" => "/one"}}} = Task.await(task)

    child =
      spawn(fn ->
        receive do
          :go ->
            send(
              owner,
              {:child,
               HTTPClient.post(
                 url: "http://test/two",
                 body: "encoded",
                 plug: {HTTPClient.Test, __MODULE__}
               )}
            )
        end
      end)

    :ok = HTTPClient.Test.allow(__MODULE__, owner, child)
    send(child, :go)
    assert_receive {:child, {:ok, %Response{body: %{"path" => "/two"}}}}
  end

  test "unsupported options fail closed and HTTP dates round trip" do
    for options <- [
          [retry: true],
          [redirect: true],
          [compressed: true],
          [proxy: "http://test"],
          [connect_options: [protocols: [:http2]]]
        ] do
      assert {:error, %TransportError{phase: :pre_transmission, reason: :invalid_options}} =
               HTTPClient.request([url: "http://127.0.0.1:1/"] ++ options)
    end

    assert HTTPClient.format_http_date(~U[2024-01-01 09:00:00Z]) ==
             "Mon, 01 Jan 2024 09:00:00 GMT"

    assert {:ok, ~U[2024-01-01 09:00:00Z]} =
             HTTPClient.parse_http_date("Mon, 01 Jan 2024 09:00:00 GMT")

    assert {:error, :invalid_date} = HTTPClient.parse_http_date("not a date")
  end

  test "invalid keyword, URI and header shapes fail before native I/O" do
    for options <- [
          [:bad],
          [url: "http://user:secret@127.0.0.1:1/"],
          [url: "http://127.0.0.1:1/path#fragment"],
          [url: "http://127.0.0.1:1/bad path"],
          [url: "http://127.0.0.1:1/", method: "REPORT BAD"],
          [
            url: "http://127.0.0.1:1/",
            headers: [{"authorization", "secret\r\nInjected: header"}]
          ],
          [url: "http://127.0.0.1:1/", ssl: [:invalid]]
        ] do
      assert {:error, %TransportError{reason: :invalid_options, phase: :pre_transmission}} =
               HTTPClient.request(options)
    end
  end

  test "declared body and identity-only encoding policies cancel before reading a body" do
    for {headers, options, reason} <- [
          {"Content-Length: 5\r\n", [max_body_bytes: 4], :response_limit},
          {"Content-Length: 5\r\nContent-Encoding: gzip\r\n", [require_identity_encoding: true],
           :unsupported_content_encoding}
        ] do
      {url, task} =
        server(fn socket, _, owner ->
          read_request(socket)
          :ok = :gen_tcp.send(socket, ["HTTP/1.1 200 OK\r\n", headers, "\r\n"])
          send(owner, {:peer_closed, :gen_tcp.recv(socket, 0, 3_000)})
        end)

      assert {:error, %TransportError{reason: ^reason}} =
               HTTPClient.request([url: url] ++ options)

      assert_receive {:peer_closed, {:error, :closed}}, 1_000
      Task.await(task)
    end
  end

  test "initial and trailing headers share one combined limit" do
    {url, task} =
      server(fn socket, _, _ ->
        read_request(socket)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-First: 1\r\n\r\n0\r\nX-Last: 2\r\n\r\n"
          )
      end)

    assert {:error, %TransportError{reason: :header_limit}} =
             HTTPClient.request(url: url, max_header_count: 2)

    Task.await(task)
  end

  test "valid extension method tokens retain binary case and request bytes" do
    {url, task} =
      server(fn socket, _, _ ->
        assert {"Custom-Method /wire HTTP/1.1" <> _, "XML"} = read_request(socket)
        response(socket, "ok")
      end)

    assert {:ok, %Response{body: "ok"}} =
             HTTPClient.request(url: url, method: "Custom-Method", body: "XML")

    Task.await(task)
  end

  test "response header count is bounded before body consumption" do
    {url, task} =
      server(fn s, _, p ->
        read_request(s)

        :gen_tcp.send(
          s,
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-One: a\r\nX-Two: b\r\n\r\n"
        )

        send(p, {:peer_closed, :gen_tcp.recv(s, 0, 3_000)})
      end)

    assert {:error, %TransportError{reason: :header_limit}} =
             HTTPClient.request(url: url, max_header_count: 2)

    assert_receive {:peer_closed, {:error, :closed}}, 1_000
    Task.await(task)
  end

  test "buffered chunked response preserves trailers" do
    {url, task} =
      server(fn s, _, _ ->
        read_request(s)

        :gen_tcp.send(
          s,
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: x-checksum\r\n\r\n3\r\none\r\n0\r\nx-checksum: fake-checksum\r\n\r\n"
        )
      end)

    assert {:ok, %Response{body: "one", trailers: %{"x-checksum" => ["fake-checksum"]}}} =
             HTTPClient.request(url: url)

    Task.await(task)
  end

  test "test callback assertion failures reach the test owner" do
    HTTPClient.Test.expect(__MODULE__, fn _conn ->
      raise ExUnit.AssertionError, message: "callback assertion"
    end)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        HTTPClient.request(url: "http://test/", plug: {HTTPClient.Test, __MODULE__})
      end

    assert error.message == "callback assertion"
  end

  @tag :tmp_dir
  test "ex_ssl verifies caller trust, returns raw bytes and cancels a lazy body", %{
    tmp_dir: tmp_dir
  } do
    certificate = Path.join(tmp_dir, "certificate.pem")
    key = Path.join(tmp_dir, "key.pem")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-days",
          "1",
          "-keyout",
          key,
          "-out",
          certificate,
          "-subj",
          "/CN=localhost",
          "-addext",
          "subjectAltName=DNS:localhost"
        ],
        stderr_to_stdout: true
      )

    [{:Certificate, der, _}] = :public_key.pem_decode(File.read!(certificate))

    for mode <- [:buffer, :cancel] do
      {:ok, listener} =
        :ssl.listen(0, [
          :binary,
          active: false,
          certfile: String.to_charlist(certificate),
          keyfile: String.to_charlist(key),
          versions: [:"tlsv1.3"]
        ])

      {:ok, {_, port}} = :ssl.sockname(listener)
      parent = self()

      task =
        Task.async(fn ->
          {:ok, transport} = :ssl.transport_accept(listener, 5_000)
          {:ok, socket} = :ssl.handshake(transport, 5_000)
          {:ok, request} = :ssl.recv(socket, 0, 5_000)
          assert request =~ "GET /tls HTTP/1.1"

          try do
            case mode do
              :buffer ->
                :ssl.send(
                  socket,
                  "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\none"
                )

              :cancel ->
                :ssl.send(
                  socket,
                  "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\none\r\n"
                )

                send(parent, {:tls_peer_closed, :ssl.recv(socket, 0, 5_000)})
            end
          after
            :ssl.close(socket)
            :ssl.close(listener)
          end
        end)

      assert {:ok, %Response{body: body}} =
               HTTPClient.request(
                 url: "https://localhost:#{port}/tls",
                 tls_backend: :ex_ssl,
                 ssl: [cacerts: [der]],
                 decode_body: false,
                 stream_response: mode == :cancel,
                 receive_timeout: 5_000
               )

      case mode do
        :buffer ->
          assert body == "one"

        :cancel ->
          assert Enum.take(body, 1) == ["one"]
          assert_receive {:tls_peer_closed, {:error, :closed}}, 3_000
      end

      Task.await(task, 5_000)
    end
  end

  test "ordinary gzip JSON is decoded with raw byte accounting" do
    body = :zlib.gzip(~s({"ok":true}))

    {url, task} =
      server(fn s, _, _ ->
        read_request(s)
        response(s, body, "Content-Encoding: gzip\r\nContent-Type: application/json\r\n")
      end)

    assert {:ok,
            %Response{body: %{"ok" => true}, headers: headers, private: %{raw_body_size: size}}} =
             HTTPClient.request(url: url)

    assert size == byte_size(body)
    refute Map.has_key?(headers, "content-encoding")
    refute Map.has_key?(headers, "content-length")
    Task.await(task)
  end

  test "decoded size limit stops compressed expansion" do
    body = :zlib.gzip(String.duplicate("x", 2_000_000))
    assert byte_size(body) < 10_000

    {url, task} =
      server(fn s, _, _ ->
        read_request(s)
        response(s, body, "Content-Encoding: gzip\r\n")
      end)

    assert {:error, %TransportError{reason: :response_limit}} =
             HTTPClient.request(url: url, max_body_bytes: 10_000)

    Task.await(task)
  end

  test "unconsumed response can be cancelled explicitly" do
    {url, task} =
      server(fn s, _, p ->
        read_request(s)
        :gen_tcp.send(s, "HTTP/1.1 500 Error\r\nTransfer-Encoding: chunked\r\n\r\n3\r\none\r\n")
        send(p, {:peer_closed, :gen_tcp.recv(s, 0, 3_000)})
      end)

    assert {:ok, %Response{status: 500} = result} =
             HTTPClient.request(url: url, stream_response: true)

    assert HTTPClient.cancel(result) == :ok
    assert_receive {:peer_closed, {:error, :closed}}, 1_000
    assert HTTPClient.cancel(result) == :ok
    Task.await(task)
  end

  test "unconsumed successful response is bounded by its request deadline" do
    {url, task} =
      server(fn s, _, p ->
        read_request(s)
        :gen_tcp.send(s, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\none\r\n")
        send(p, {:peer_closed, :gen_tcp.recv(s, 0, 3_000)})
      end)

    assert {:ok, %Response{} = result} =
             HTTPClient.request(url: url, stream_response: true, receive_timeout: 100)

    assert_receive {:peer_closed, {:error, :closed}}, 1_000
    assert HTTPClient.cancel(result) == :ok
    Task.await(task)
  end

  test "empty abandoned stream releases its controller and completion tracker" do
    {url, task} =
      server(fn s, _, _ ->
        read_request(s)
        response(s, "")
      end)

    assert {:ok, %Response{} = result} =
             HTTPClient.request(url: url, stream_response: true, receive_timeout: 100)

    # Explicit cancellation is also a completion barrier for an empty unread body.
    assert HTTPClient.cancel(result) == :ok
    Task.await(task)
  end

  test "caller death aborts a dispatched request before its long deadline" do
    {url, task} =
      server(fn s, _, p ->
        read_request(s)
        send(p, :request_on_wire)
        send(p, {:peer_closed, :gen_tcp.recv(s, 0, 3_000)})
      end)

    {caller, monitor} =
      spawn_monitor(fn -> HTTPClient.request(url: url, receive_timeout: 10_000) end)

    assert_receive :request_on_wire, 1_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    assert_receive {:peer_closed, {:error, :closed}}, 1_000
    Task.await(task)
  end
end
