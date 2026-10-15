defmodule Manifold.Connectors.DAV.TransportTest do
  use ExUnit.Case, async: true
  alias Manifold.Connectors.DAV.Transport

  test "DNS nonexistence remains distinguishable for regional discovery" do
    assert {:error, :nxdomain} =
             Transport.request(:get, "https://manifold-dav-no-such-host.invalid/", [], nil,
               timeout: 5_000
             )
  end

  test "native HTTP dispatch preserves extension methods, XML and authorization" do
    body = "<D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>\n"
    response = "<D:multistatus xmlns:D=\"DAV:\">原样</D:multistatus>\n"

    for method <- [:propfind, :report, :mkcalendar, :put, :delete, "X-CUSTOM"] do
      {url, peer} =
        server([
          "HTTP/1.1 207 Multi-Status\r\nContent-Type: application/xml\r\n",
          "Content-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n",
          response
        ])

      assert {:ok, %{status: 207, body: ^response}} =
               Transport.request(
                 method,
                 url,
                 [{"authorization", "Basic dummy"}, {"depth", "1"}],
                 body
               )

      request = Task.await(peer)
      assert request =~ "#{method |> to_string() |> String.upcase()} / HTTP/1.1"
      assert String.downcase(request) =~ "authorization: basic dummy"
      assert [_headers, ^body] = String.split(request, "\r\n\r\n", parts: 2)
    end
  end

  test "invalid extension tokens fail before dispatch" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)

    for method <- ["BAD METHOD", "REPORT\r\nX-Header: injected", "REPORT\0", "Méthod"] do
      assert {:error, :transport_failure} =
               Transport.request(method, "http://127.0.0.1:#{port}/", [], "<xml/>")

      assert {:error, :timeout} = :gen_tcp.accept(listener, 25)
    end
  end

  test "transport does not automatically follow redirects or retry errors" do
    {url, peer} =
      server(
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )

    assert {:ok, %{status: 302, body: ""}} = Transport.request(:get, url, [], nil)
    Task.await(peer)

    {url, peer} =
      server("HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

    assert {:ok, %{status: 503}} = Transport.request(:get, url, [], nil)
    Task.await(peer)
  end

  test "streamed response byte limit fails instead of returning truncated success" do
    {url, peer} =
      server(
        "HTTP/1.1 200 OK\r\nContent-Length: 200\r\nConnection: close\r\n\r\n" <>
          String.duplicate("a", 200)
      )

    assert {:error, :response_limit} = Transport.request(:get, url, [], nil, max_body_bytes: 100)
    Task.await(peer)
  end

  test "HTTP response header parser enforces a finite byte limit" do
    {url, peer} =
      server(
        "HTTP/1.1 200 OK\r\nX-Huge: " <>
          String.duplicate("a", 70_000) <> "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )

    assert {:error, :header_limit} = Transport.request(:get, url, [], nil)
    Task.await(peer)
  end

  test "DAV metadata from HTTP trailers remains available in response headers" do
    {url, peer} =
      server(
        "HTTP/1.1 207 Multi-Status\r\nTransfer-Encoding: chunked\r\nTrailer: ETag\r\n" <>
          "Connection: close\r\n\r\n3\r\nxml\r\n0\r\nETag: \"trailing\"\r\n\r\n"
      )

    assert {:ok, %{status: 207, body: "xml", headers: headers}} =
             Transport.request(:report, url, [], "<report/>")

    assert headers["etag"] == ["\"trailing\""]
    Task.await(peer)
  end

  test "response header field bound also counts trailers" do
    headers = Enum.map_join(1..997, "", &"X-Field-#{&1}: value\r\n")
    trailers = "X-Trailer-1: value\r\nX-Trailer-2: value\r\n"

    {url, peer} =
      server(
        "HTTP/1.1 207 Multi-Status\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n" <>
          headers <> "\r\n0\r\n" <> trailers <> "\r\n"
      )

    assert {:error, :header_limit} = Transport.request(:report, url, [], "<report/>")
    Task.await(peer)
  end

  test "peer closing without an HTTP response remains a transport failure" do
    {url, peer} = server("")

    assert {:error, :transport_failure} = Transport.request(:get, url, [], nil)
    assert Task.await(peer) =~ "GET / HTTP/1.1"
  end

  test "DAV request credentials never enter HTTP telemetry" do
    handler = "dav-no-credential-telemetry-#{System.unique_integer([:positive])}"

    events = [
      [:finch, :request, :start],
      [:finch, :request, :stop],
      [:finch, :connect, :start],
      [:finch, :connect, :stop],
      [:finch, :send, :start],
      [:finch, :send, :stop],
      [:finch, :recv, :start],
      [:finch, :recv, :stop],
      [:http_fetch, :request, :start],
      [:http_fetch, :request, :stop],
      [:http_fetch, :request, :exception],
      [:http_fetch, :streaming, :start],
      [:http_fetch, :streaming, :chunk],
      [:http_fetch, :streaming, :stop]
    ]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, _, metadata, parent -> send(parent, {:http_event, event, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {url, peer} = server("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nsafe")
    secret = Base.encode64("dummy-apple-id:dummy-app-password")

    assert {:ok, %{status: 200, body: "safe"}} =
             Transport.request(:get, url, [{"authorization", "Basic " <> secret}], nil)

    assert Task.await(peer) =~ secret
    refute_received {:http_event, _, _}
  end

  test "absolute request timeout terminates a stalled peer" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        _ = read_request(socket, "")
        send(parent, :peer_received)
        result = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        result
      end)

    assert {:error, :timeout} =
             Transport.request(:get, "http://127.0.0.1:#{port}/", [], nil, timeout: 500)

    assert_received :peer_received
    assert {:error, :closed} = Task.await(peer)
  end

  test "absolute deadline includes a partially received DAV response body" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        request = read_request(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 207 Multi-Status\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n"
          )

        send(parent, {:partial_dav_response, request})
        result = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        result
      end)

    assert {:error, :timeout} =
             Transport.request(:report, "http://127.0.0.1:#{port}/", [], "<report/>",
               timeout: 500
             )

    assert_received {:partial_dav_response, request}
    assert request =~ "REPORT / HTTP/1.1"
    assert {:error, :closed} = Task.await(peer)
  end

  test "response header field count is bounded independently of byte size" do
    headers = Enum.map_join(1..1_001, "", &"X-Field-#{&1}: value\r\n")

    {url, peer} =
      server(
        "HTTP/1.1 207 Multi-Status\r\n" <>
          headers <>
          "Content-Length: 0\r\nConnection: close\r\n\r\n"
      )

    assert {:error, :header_limit} = Transport.request(:propfind, url, [], "<propfind/>")
    Task.await(peer)
  end

  defp server(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        request = read_request(socket, "")
        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        request
      end)

    {"http://127.0.0.1:#{port}/", peer}
  end

  defp read_request(socket, buffer) do
    complete? =
      case String.split(buffer, "\r\n\r\n", parts: 2) do
        [headers, body] ->
          length =
            case Regex.run(~r/content-length: ([0-9]+)/i, headers) do
              [_, length] -> String.to_integer(length)
              _ -> 0
            end

          byte_size(body) >= length

        _ ->
          false
      end

    if complete? do
      buffer
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
      read_request(socket, buffer <> chunk)
    end
  end
end
