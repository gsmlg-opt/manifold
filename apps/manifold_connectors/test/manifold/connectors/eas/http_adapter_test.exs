Code.require_file("../../../support/tls_peer.exs", __DIR__)

defmodule Manifold.Connectors.EAS.HTTPAdapterTest do
  use ExUnit.Case, async: false

  alias Manifold.Connectors.EAS.{Client, HTTPAdapter, WBXML}
  alias Manifold.Connectors.TLS
  alias Manifold.TestSupport.TLSPeer
  alias SSL.ClientHello.WireProfile
  alias SSL.Protocol.{ClientOffer, HandshakeFramer, RecordFramer}

  test "EAS OPTIONS and FolderSync use ex_ssl with auth, cookies, and binary WBXML" do
    test_pid = self()
    folder_response = folder_sync_response()

    {:ok, peer} =
      TLSPeer.start_many(
        fn socket, index ->
          {:ok, request} = recv_request(socket)
          send(test_pid, {:http_request, index, request})

          response =
            case index do
              1 ->
                http_response(200, <<>>, [
                  {"MS-ASProtocolVersions", "14.0,14.1"},
                  {"Set-Cookie", "session=bound; Path=/; Secure"}
                ])

              2 ->
                http_response(200, folder_response, [
                  {"Content-Type", "application/vnd.ms-sync.wbxml"}
                ])
            end

          :ok = :ssl.send(socket, response)
          :ok = :ssl.close(socket)
        end,
        2
      )

    assert {:ok, conn} = Client.connect(settings(peer.port))
    assert {:ok, _conn, result} = Client.folder_sync(conn, "0")
    assert result.sync_key == "123"
    assert [%{server_id: "inbox", display_name: "Inbox", type: "2"}] = result.folders

    assert_receive {:http_request, 1, %{method: "OPTIONS", headers: options_headers}}

    assert header(options_headers, "authorization") ==
             "Basic " <> Base.encode64("user@ex.com:secret")

    assert_receive {:http_request, 2, %{method: "POST", headers: post_headers, body: body}}
    assert header(post_headers, "cookie") == "session=bound"
    assert header(post_headers, "content-type") == "application/vnd.ms-sync.wbxml"
    assert {:ok, {_page, "FolderSync", _children}} = WBXML.decode(body)

    assert [:ok, :ok] = TLSPeer.stop(peer)
  end

  test "adapter handles large fragmented content-length responses" do
    body = :binary.copy("response-fragment-", 70_000)

    {:ok, peer} =
      TLSPeer.start(fn socket ->
        {:ok, _request} = recv_request(socket)
        head = response_head(200, byte_size(body), [])
        :ok = :ssl.send(socket, head)

        body
        |> chunks(4_093)
        |> Enum.each(fn chunk -> :ok = :ssl.send(socket, chunk) end)

        :ok = :ssl.close(socket)
      end)

    assert {:ok, %Req.Response{status: 200, body: ^body}} = request(peer.port)
    assert :ok = TLSPeer.stop(peer)
  end

  test "adapter handles chunked responses with trailers" do
    {:ok, peer} =
      TLSPeer.start(fn socket ->
        {:ok, _request} = recv_request(socket)

        response = [
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
          ~S(5;name=value;note="a\"b") <> "\r\nhello\r\n",
          "6\r\n world\r\n",
          "0\r\nX-Result: complete\r\n\r\n"
        ]

        response
        |> IO.iodata_to_binary()
        |> chunks(3)
        |> Enum.each(fn chunk -> :ok = :ssl.send(socket, chunk) end)

        :ok = :ssl.close(socket)
      end)

    assert {:ok, %Req.Response{body: "hello world", trailers: trailers}} = request(peer.port)
    assert {"x-result", "complete"} in Req.Fields.get_list(trailers)
    assert :ok = TLSPeer.stop(peer)
  end

  test "authenticated close delimits a response body" do
    {:ok, peer} =
      TLSPeer.start(fn socket ->
        {:ok, _request} = recv_request(socket)
        :ok = :ssl.send(socket, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\ncomplete")
        :ok = :ssl.close(socket)
      end)

    assert {:ok, %Req.Response{body: "complete"}} = request(peer.port)
    assert :ok = TLSPeer.stop(peer)
  end

  test "compressed responses are rejected before Req response processing" do
    {:ok, peer} =
      TLSPeer.start(fn socket ->
        {:ok, _request} = recv_request(socket)

        :ok =
          :ssl.send(
            socket,
            http_response(200, "compressed bytes", [{"Content-Encoding", "gzip"}])
          )

        :ok = :ssl.close(socket)
      end)

    assert {:error, %Req.HTTPError{reason: :unsupported_content_encoding}} = request(peer.port)
    assert :ok = TLSPeer.stop(peer)
  end

  test "certificate and transport failures surface without fallback" do
    {:ok, untrusted_peer} =
      TLSPeer.start(fn socket ->
        _ = recv_request(socket)
        :ssl.close(socket)
      end)

    untrusted_options =
      replace_option(TLSPeer.client_options(), :cacerts, :public_key.cacerts_get())

    assert {:error, %Req.TransportError{}} = request(untrusted_peer.port, untrusted_options)
    assert {:handshake_error, _reason} = TLSPeer.stop(untrusted_peer)

    {:ok, observer} = TLSPeer.observe_client_hello(self())

    assert {:error, %Req.TransportError{}} = request(observer.port)
    assert_receive {:client_hello_observed, _bytes}
    assert :ok = Task.await(observer.task, 6_000)
  end

  test "abrupt TCP loss cannot complete a close-delimited HTTP response" do
    parent = self()

    {:ok, peer} =
      TLSPeer.start(fn socket ->
        {:ok, _request} = recv_request(socket)
        :ok = :ssl.send(socket, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\npartial body")
        send(parent, :partial_http_response_sent)
        assert {:error, _reason} = :ssl.recv(socket, 0, 5_000)
        :ok
      end)

    {:ok, proxy} = TLSPeer.start_fragmenting_proxy(peer.port, self())
    response = Task.async(fn -> request(proxy.port) end)
    assert_receive :partial_http_response_sent, 5_000
    Task.shutdown(proxy.task, :brutal_kill)
    :gen_tcp.close(proxy.listener)

    assert {:error, %Req.TransportError{reason: :econnreset}} = Task.await(response, 5_000)
    assert :ok = TLSPeer.stop(peer)
  end

  test "one receive deadline is retained across response fragments" do
    {:ok, peer} =
      TLSPeer.start(fn socket ->
        {:ok, _request} = recv_request(socket)
        _ = :ssl.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\na")
        Process.sleep(80)
        _ = :ssl.send(socket, "bcd")
        :ssl.close(socket)
      end)

    assert {:error, %Req.TransportError{reason: :timeout}} = request(peer.port, nil, 30)
    assert :ok = TLSPeer.stop(peer)
  end

  test "malformed or oversized response framing fails and releases each connection" do
    cases = [
      {"conflicting transfer framing",
       "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n0\r\n\r\n",
       %Req.HTTPError{reason: :conflicting_response_framing}},
      {"invalid chunk terminator",
       "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\naX0\r\n\r\n",
       %Req.HTTPError{reason: :invalid_chunk_terminator}},
      {"chunk size with leading whitespace",
       "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n 1\r\na\r\n0\r\n\r\n",
       %Req.HTTPError{reason: :invalid_chunk_size}},
      {"chunk size with trailing whitespace",
       "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1 \r\na\r\n0\r\n\r\n",
       %Req.HTTPError{reason: :invalid_chunk_size}},
      {"chunk size with NUL",
       "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\0\r\na\r\n0\r\n\r\n",
       %Req.HTTPError{reason: :invalid_chunk_size}},
      {"malformed chunk extension",
       "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;name=\"unterminated\r\na\r\n0\r\n\r\n",
       %Req.HTTPError{reason: :invalid_chunk_size}},
      {"out-of-range response status", "HTTP/1.1 600 Invalid\r\nContent-Length: 0\r\n\r\n",
       %Req.HTTPError{reason: :invalid_status_line}},
      {"truncated declared body", "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc",
       %Req.TransportError{reason: :closed}},
      {"oversized content length", "HTTP/1.1 200 OK\r\nContent-Length: 67108865\r\n\r\n",
       %Req.HTTPError{reason: :invalid_content_length}},
      {"oversized header",
       ["HTTP/1.1 200 OK\r\nX-Large: ", :binary.copy("x", 65_536), "\r\n\r\n"],
       %Req.HTTPError{reason: :headers_too_large}}
    ]

    Enum.each(cases, fn {name, response, expected_error} ->
      existing_connections = connection_pids()

      {:ok, peer} =
        TLSPeer.start(fn socket ->
          {:ok, _request} = recv_request(socket)
          _ = :ssl.send(socket, response)
          _ = :ssl.close(socket)
          :ok
        end)

      assert {:error, error} = request(peer.port), name
      assert error.__struct__ == expected_error.__struct__, name
      assert Map.get(error, :reason) == Map.get(expected_error, :reason), name
      assert :ok = TLSPeer.stop(peer)
      assert_no_new_connections(existing_connections)
    end)
  end

  test "selected HTTP/1.1 WireProfile reaches the controlled server" do
    test_pid = self()

    profile = %WireProfile{
      name: :eas_http1_test,
      cipher_suites: [0x1301],
      extensions: [
        {:server_name, :from_connection},
        {:supported_versions, [0x0304]},
        {:supported_groups, [0x001D, 0x0017]},
        {:signature_algorithms, [0x0403, 0x0804]},
        {:key_share, [0x001D]},
        {:alpn, ["http/1.1"]},
        {:padding, {:fixed, 17}}
      ]
    }

    {:ok, peer} =
      TLSPeer.start(fn socket ->
        {:ok, request} = recv_request(socket)
        send(test_pid, {:profile_http_request, request})

        :ok =
          :ssl.send(
            socket,
            http_response(200, <<>>, [{"MS-ASProtocolVersions", "14.0,14.1"}])
          )

        :ok = :ssl.close(socket)
      end)

    {:ok, proxy} = TLSPeer.start_fragmenting_proxy(peer.port, self())

    profile_settings =
      put_in(
        settings(proxy.port),
        [:tls, :options],
        Keyword.put(tls_overrides(), :ex_ssl, profile: profile)
      )

    assert {:ok, _conn} = Client.connect(profile_settings)
    assert_receive {:profile_http_request, %{method: "OPTIONS", target: target}}
    assert String.starts_with?(target, "/Microsoft-Server-ActiveSync")

    assert {:ok, offer} = receive_client_offer(proxy.ref)
    assert offer.cipher_suites == [0x1301]
    assert offer.alpn_protocols == ["http/1.1"]
    assert 21 in offer.extension_ids

    _ = TLSPeer.stop_fragmenting_proxy(proxy)
    assert :ok = TLSPeer.stop(peer)
  end

  test "HTTP/2 profiles and unsupported request options fail before network activity" do
    h2_profile = %WireProfile{
      extensions: [
        {:supported_versions, [0x0304]},
        {:supported_groups, [0x001D]},
        {:signature_algorithms, [0x0403]},
        {:key_share, [0x001D]},
        {:alpn, ["h2", "http/1.1"]}
      ]
    }

    config = tls_config(replace_option(TLSPeer.client_options(), :ex_ssl, profile: h2_profile))

    assert {:error, :unsupported_ex_ssl_http_options} =
             HTTPAdapter.validate_options([receive_timeout: 10, decode_body: false], config)

    config = tls_config(TLSPeer.client_options())

    assert {:error, :unsupported_ex_ssl_http_options} =
             HTTPAdapter.validate_options([plug: {Req.Test, __MODULE__}], config)

    assert {:error, :unsupported_ex_ssl_http_options} =
             HTTPAdapter.validate_options([decode_body: true], config)
  end

  test "malformed bodies and adapter options return Req errors before network activity" do
    {listener, port} = tcp_listener()
    on_exit(fn -> :gen_tcp.close(listener) end)

    request = adapter_request(port)
    config = tls_config(TLSPeer.client_options())

    malformed_requests = [
      {%{request | body: [<<1>>, {:not, :iodata}]}, :unsupported_request_body},
      {%{request | options: Map.put(request.options, :decode_body, true)},
       :unsafe_request_policy},
      {HTTPAdapter.put_tls_config(
         request,
         %{config | options: replace_option(config.options, :ex_ssl, :not_a_keyword)}
       ), :unsafe_request_policy},
      {HTTPAdapter.put_tls_config(
         request,
         %{
           config
           | options:
               replace_option(config.options, :ex_ssl,
                 profile: :default,
                 profile: :default
               )
         }
       ), :unsafe_request_policy},
      {HTTPAdapter.put_tls_config(
         request,
         %{
           config
           | options:
               replace_option(config.options, :ex_ssl,
                 profile: :default,
                 unsupported: "secret-option-value"
               )
         }
       ), :unsafe_request_policy},
      {HTTPAdapter.put_tls_config(
         request,
         %{
           config
           | options:
               replace_option(config.options, :ex_ssl,
                 profile: %WireProfile{extensions: :not_a_list}
               )
         }
       ), :unsafe_request_policy}
    ]

    Enum.each(malformed_requests, fn {malformed_request, reason} ->
      assert {_request, %Req.HTTPError{reason: ^reason}} = HTTPAdapter.run(malformed_request)
      assert {:error, :timeout} = :gen_tcp.accept(listener, 25)
    end)
  end

  test "full request head size and final injected header count are bounded before connect" do
    {listener, port} = tcp_listener()
    on_exit(fn -> :gen_tcp.close(listener) end)

    oversized_target = "/" <> :binary.copy("a", 65_500)

    target_request =
      adapter_request(port, nil, url: "https://127.0.0.1:#{port}#{oversized_target}")

    assert {_request, %Req.HTTPError{reason: :request_headers_too_large}} =
             HTTPAdapter.run(target_request)

    assert {:error, :timeout} = :gen_tcp.accept(listener, 25)

    headers = for index <- 1..198, do: {"x-header-#{index}", "v"}
    header_request = %{adapter_request(port) | headers: Req.Fields.new(headers)}

    assert {_request, %Req.HTTPError{reason: :request_headers_too_large}} =
             HTTPAdapter.run(header_request)

    assert {:error, :timeout} = :gen_tcp.accept(listener, 25)
  end

  test "invalid ex_ssl request options do not expose their values" do
    sentinel = "password-token-sentinel"
    invalid_settings = Map.put(settings(443), :req_options, receive_timeout: sentinel)

    assert {:error, error} = Client.connect(invalid_settings)
    refute error.message =~ sentinel
    assert error.message =~ "unsupported_ex_ssl_http_options"
  end

  defp request(port, tls_options \\ nil, receive_timeout \\ 5_000) do
    port
    |> adapter_request(tls_options, receive_timeout: receive_timeout)
    |> Req.request()
  end

  defp adapter_request(port, tls_options \\ nil, overrides \\ []) do
    tls_options = tls_options || TLSPeer.client_options()
    config = tls_config(tls_options)

    [
      method: :post,
      url: "https://127.0.0.1:#{port}/Microsoft-Server-ActiveSync?Cmd=Sync",
      headers: [{"content-type", "application/vnd.ms-sync.wbxml"}],
      body: <<0, 1, 2, 3>>,
      adapter: HTTPAdapter,
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000, protocols: [:http1]]
    ]
    |> Keyword.merge(overrides)
    |> Req.new()
    |> HTTPAdapter.put_tls_config(config)
  end

  defp tcp_listener do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    {listener, port}
  end

  defp tls_config(options),
    do: %TLS.Config{backend: :ex_ssl, options: Enum.reject(options, &(&1 == :binary))}

  defp replace_option(options, key, value) do
    [
      {key, value}
      | Enum.reject(options, fn
          {^key, _value} -> true
          _option -> false
        end)
    ]
  end

  defp settings(port) do
    %{
      host: "127.0.0.1",
      port: port,
      path: "/Microsoft-Server-ActiveSync",
      username: "user@ex.com",
      password: "secret",
      device_id: "ApplABCD1234EFGH",
      device_type: "iPhone",
      protocol_version: "14.1",
      emit_activity: false,
      tls: [backend: :ex_ssl, options: tls_overrides()]
    }
  end

  defp tls_overrides do
    allowed = [
      :cacerts,
      :cacertfile,
      :server_name_indication,
      :customize_hostname_check,
      :versions,
      :ex_ssl
    ]

    Enum.filter(TLSPeer.client_options(), fn
      {key, _value} -> key in allowed
      _option -> false
    end)
  end

  defp folder_sync_response do
    WBXML.encode(
      {5, "FolderSync",
       [
         {5, "Status", ["1"]},
         {5, "SyncKey", ["123"]},
         {5, "Changes",
          [
            {5, "Add",
             [
               {5, "ServerId", ["inbox"]},
               {5, "ParentId", ["0"]},
               {5, "DisplayName", ["Inbox"]},
               {5, "Type", ["2"]}
             ]}
          ]}
       ]}
    )
  end

  defp http_response(status, body, headers) do
    [response_head(status, byte_size(body), headers), body]
  end

  defp response_head(status, length, headers) do
    headers = [{"Content-Length", Integer.to_string(length)}, {"Connection", "close"} | headers]

    [
      "HTTP/1.1 #{status} OK\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]
  end

  defp recv_request(socket, buffer \\ <<>>) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, 4} ->
        <<head::binary-size(index), _separator::binary-size(4), rest::binary>> = buffer
        [request_line | header_lines] = :binary.split(head, "\r\n", [:global])
        [method, target, "HTTP/1.1"] = String.split(request_line, " ")

        headers =
          Map.new(header_lines, fn line ->
            [name, value] = :binary.split(line, ":")
            {String.downcase(name), String.trim(value)}
          end)

        length = headers |> Map.get("content-length", "0") |> String.to_integer()

        with {:ok, body} <- recv_exact(socket, rest, length) do
          {:ok, %{method: method, target: target, headers: headers, body: body}}
        end

      :nomatch ->
        with {:ok, bytes} <- :ssl.recv(socket, 0, 5_000) do
          recv_request(socket, buffer <> bytes)
        end
    end
  end

  defp recv_exact(_socket, buffer, length) when byte_size(buffer) == length, do: {:ok, buffer}

  defp recv_exact(socket, buffer, length) when byte_size(buffer) < length do
    with {:ok, bytes} <- :ssl.recv(socket, 0, 5_000) do
      recv_exact(socket, buffer <> bytes, length)
    end
  end

  defp header(headers, name), do: Map.fetch!(headers, name)

  defp chunks(binary, size),
    do: for(<<chunk::binary-size(size) <- binary>>, do: chunk) ++ tail(binary, size)

  defp tail(binary, size) do
    remainder = rem(byte_size(binary), size)

    if remainder == 0,
      do: [],
      else: [binary_part(binary, byte_size(binary) - remainder, remainder)]
  end

  defp receive_client_offer(ref) do
    receive_client_offer(ref, RecordFramer.new(), HandshakeFramer.new())
  end

  defp receive_client_offer(ref, record_framer, handshake_framer) do
    receive do
      {:tls_proxy, ^ref, :client_to_server, bytes} ->
        {:ok, records, record_framer} = RecordFramer.feed(record_framer, bytes)

        case feed_handshakes(records, handshake_framer) do
          {:ok, offer, _framer} -> {:ok, offer}
          {:more, handshake_framer} -> receive_client_offer(ref, record_framer, handshake_framer)
        end

      {:tls_proxy, ^ref, :server_to_client, _bytes} ->
        receive_client_offer(ref, record_framer, handshake_framer)
    after
      5_000 -> {:error, :client_hello_not_observed}
    end
  end

  defp feed_handshakes([], framer), do: {:more, framer}

  defp feed_handshakes(
         [<<22, _version::16, length::16, payload::binary-size(length)>> | records],
         framer
       ) do
    {:ok, messages, framer} = HandshakeFramer.feed(framer, payload)

    case Enum.find_value(messages, fn message ->
           case ClientOffer.from_client_hello(message) do
             {:ok, offer} -> offer
             _ -> nil
           end
         end) do
      nil -> feed_handshakes(records, framer)
      offer -> {:ok, offer, framer}
    end
  end

  defp feed_handshakes([_record | records], framer), do: feed_handshakes(records, framer)

  defp connection_pids do
    SSL.ConnectionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> MapSet.new()
  end

  defp assert_no_new_connections(existing, attempts \\ 20)

  defp assert_no_new_connections(existing, 0) do
    assert MapSet.subset?(connection_pids(), existing)
  end

  defp assert_no_new_connections(existing, attempts) do
    if MapSet.subset?(connection_pids(), existing) do
      :ok
    else
      Process.sleep(10)
      assert_no_new_connections(existing, attempts - 1)
    end
  end
end
