Code.require_file("../../../support/tls_peer.exs", __DIR__)

defmodule Manifold.Connectors.EAS.ExSSLClientSafetyTest do
  use ExUnit.Case, async: false

  alias Manifold.Connectors.EAS.{Client, WBXML}
  alias Manifold.Connectors.Provider.Error
  alias Manifold.TestSupport.TLSPeer

  test "ex_ssl preserves response bytes for WBXML validation" do
    sentinel = "response-secret-sentinel"

    {:ok, peer} =
      TLSPeer.start_many(
        fn socket, index ->
          {:ok, _request} = recv_request(socket)

          response =
            case index do
              1 ->
                http_response(200, <<>>, [])

              2 ->
                http_response(200, ~s({"token":"#{sentinel}"}), [
                  {"Content-Type", "application/json"}
                ])
            end

          :ok = :ssl.send(socket, response)
          :ok = :ssl.close(socket)
        end,
        2
      )

    assert {:ok, conn} = Client.connect(settings(peer.port))

    assert {:error, %Error{code: :invalid_response} = error} = Client.folder_sync(conn, "0")
    refute error.message =~ sentinel
    refute inspect(error) =~ sentinel
    assert [:ok, :ok] = TLSPeer.stop(peer)
  end

  test "ex_ssl connect rejects unsuccessful OPTIONS responses" do
    for {status, expected_code} <- [{403, :auth_failed}, {500, :http_error}] do
      {:ok, peer} =
        TLSPeer.start(fn socket ->
          {:ok, _request} = recv_request(socket)
          :ok = :ssl.send(socket, http_response(status, "failed", []))
          :ok = :ssl.close(socket)
        end)

      assert {:error, %Error{code: ^expected_code}} = Client.connect(settings(peer.port))
      assert :ok = TLSPeer.stop(peer)
    end
  end

  test "ex_ssl does not follow an OPTIONS redirect or forward authorization" do
    test_pid = self()

    {:ok, leak_peer} =
      TLSPeer.start(fn socket ->
        {:ok, request} = recv_request(socket)
        send(test_pid, {:redirect_followed, request})
        :ok = :ssl.send(socket, http_response(200, <<>>, []))
        :ok = :ssl.close(socket)
      end)

    {:ok, redirect_peer} =
      TLSPeer.start(fn socket ->
        {:ok, _request} = recv_request(socket)

        :ok =
          :ssl.send(
            socket,
            http_response(302, <<>>, [
              {"Location", "https://127.0.0.1:#{leak_peer.port}/capture"}
            ])
          )

        :ok = :ssl.close(socket)
      end)

    try do
      assert {:error, %Error{code: :http_error}} = Client.connect(settings(redirect_peer.port))
      refute_receive {:redirect_followed, _request}, 100
    after
      _ = Task.shutdown(leak_peer.task, :brutal_kill)
      _ = :ssl.close(leak_peer.listener)
      _ = Task.shutdown(redirect_peer.task, :brutal_kill)
      _ = :ssl.close(redirect_peer.listener)
    end
  end

  test "ex_ssl does not replay a state-changing Sync POST after HTTP 400" do
    test_pid = self()
    sentinel = "http-error-secret-sentinel"

    {:ok, peer} =
      TLSPeer.start_many(
        fn socket, index ->
          {:ok, request} = recv_request(socket)
          send(test_pid, {:request, index, request})

          response =
            case index do
              1 -> http_response(200, <<>>, [])
              2 -> http_response(400, sentinel, [])
              3 -> http_response(200, change_response(), [])
            end

          :ok = :ssl.send(socket, response)
          :ok = :ssl.close(socket)
        end,
        3
      )

    try do
      assert {:ok, conn} = Client.connect(settings(peer.port))

      assert {:error, %Error{code: :http_error} = error} =
               Client.change_read(conn, %{
                 collection_id: "inbox",
                 server_id: "message-1",
                 read?: true,
                 sync_key: "1"
               })

      refute error.message =~ sentinel
      refute inspect(error) =~ sentinel

      assert_receive {:request, 1, %{method: "OPTIONS"}}
      assert_receive {:request, 2, %{method: "POST", target: target}}
      assert target =~ "Cmd=Sync"
      refute_receive {:request, 3, _request}, 100
    after
      _ = Task.shutdown(peer.task, :brutal_kill)
      _ = :ssl.close(peer.listener)
    end
  end

  test "ex_ssl does not replay Provision after HTTP 400" do
    test_pid = self()

    {:ok, peer} =
      TLSPeer.start_many(
        fn socket, index ->
          {:ok, request} = recv_request(socket)
          send(test_pid, {:provision_request, index, request})

          response =
            case index do
              1 -> http_response(200, <<>>, [])
              2 -> http_response(400, "unsupported", [])
              3 -> http_response(200, provision_response(), [])
            end

          :ok = :ssl.send(socket, response)
          :ok = :ssl.close(socket)
        end,
        3
      )

    try do
      assert {:ok, conn} = Client.connect(settings(peer.port))
      assert {:error, %Error{code: :http_error}} = Client.provision(conn)

      assert_receive {:provision_request, 1, %{method: "OPTIONS"}}
      assert_receive {:provision_request, 2, %{method: "POST", target: target}}
      assert target =~ "Cmd=Provision"
      refute_receive {:provision_request, 3, _request}, 100
    after
      _ = Task.shutdown(peer.task, :brutal_kill)
      _ = :ssl.close(peer.listener)
    end
  end

  test "explicit response decoding is rejected before ex_ssl network activity" do
    {:ok, observer} = TLSPeer.observe_client_hello(self())
    settings = settings(observer.port) |> Map.put(:req_options, decode_body: true)

    try do
      assert {:error, %Error{code: :connect_failed}} = Client.connect(settings)
      refute_receive {:client_hello_observed, _bytes}, 100
    after
      _ = Task.shutdown(observer.task, :brutal_kill)
    end
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

  defp change_response do
    WBXML.encode(
      {0, "Sync",
       [
         {0, "Collections",
          [
            {0, "Collection",
             [
               {0, "Status", ["1"]},
               {0, "SyncKey", ["2"]}
             ]}
          ]}
       ]}
    )
  end

  defp provision_response do
    WBXML.encode(
      {14, "Provision",
       [
         {14, "Status", ["1"]},
         {14, "Policies",
          [
            {14, "Policy",
             [
               {14, "PolicyType", ["MS-EAS-Provisioning-WBXML"]},
               {14, "Status", ["2"]}
             ]}
          ]}
       ]}
    )
  end

  defp http_response(status, body, headers) do
    headers = [
      {"Content-Length", Integer.to_string(byte_size(body))},
      {"Connection", "close"} | headers
    ]

    [
      "HTTP/1.1 #{status} Response\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n",
      body
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

  defp recv_exact(_socket, buffer, length) when byte_size(buffer) == length,
    do: {:ok, buffer}

  defp recv_exact(socket, buffer, length) when byte_size(buffer) < length do
    with {:ok, bytes} <- :ssl.recv(socket, 0, 5_000) do
      recv_exact(socket, buffer <> bytes, length)
    end
  end
end
