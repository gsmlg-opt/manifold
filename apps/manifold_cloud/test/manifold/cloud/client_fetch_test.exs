defmodule Manifold.Cloud.ClientFetchTest do
  use ExUnit.Case, async: true

  alias Manifold.Cloud.Client
  alias Manifold.Core.HTTPClient.TransportError
  alias Manifold.Core.SignedRequest

  test "raw delivery returns before the body arrives and remains a lazy enumerable" do
    {source, peer} =
      server(fn socket ->
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n")

        receive do
          :body -> :ok = :gen_tcp.send(socket, "raw mail")
        after
          5_000 -> flunk("client did not return before the body arrived")
        end
      end)

    assert {:ok, stream} = Client.stream_raw(source, "delivery-1")
    send(peer.pid, :body)
    assert Enum.join(stream) == "raw mail"
    assert :ok = Task.await(peer)
  end

  test "stopping raw delivery enumeration closes the real peer connection" do
    {source, peer} =
      server(fn socket ->
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")

        receive do
          :body -> :ok = :gen_tcp.send(socket, "4\r\nmail\r\n")
        after
          5_000 -> flunk("client did not request the body")
        end

        :gen_tcp.recv(socket, 0, 5_000)
      end)

    assert {:ok, stream} = Client.stream_raw(source, "delivery-1")
    send(peer.pid, :body)
    assert Enum.take(stream, 1) == ["mail"]
    assert {:error, :closed} = Task.await(peer)
  end

  test "a truncated raw delivery raises instead of reporting successful completion" do
    {source, peer} =
      server(fn socket ->
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n")

        receive do
          :body -> :ok = :gen_tcp.send(socket, "mail")
        after
          5_000 -> flunk("client did not request the body")
        end
      end)

    assert {:ok, stream} = Client.stream_raw(source, "delivery-1")
    send(peer.pid, :body)
    assert_raise TransportError, fn -> Enum.join(stream) end
    assert :ok = Task.await(peer)
  end

  test "a rejected raw delivery cancels its unconsumed response body" do
    for status <- [404, 500] do
      {source, peer} =
        server(fn socket ->
          :ok = :gen_tcp.send(socket, "HTTP/1.1 #{status} Error\r\nContent-Length: 8\r\n\r\n")
          :gen_tcp.recv(socket, 0, 5_000)
        end)

      assert {:error, error} = Client.stream_raw(source, "delivery-1")
      assert error.class == if(status == 500, do: :temporary, else: :permanent)
      assert {:error, :closed} = Task.await(peer)
    end
  end

  defp server(handler) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)

        try do
          request = read_head(socket, "")
          assert request =~ "GET /api/v1/deliveries/delivery-1/raw HTTP/1.1"
          [_request_line | fields] = String.split(request, "\r\n", trim: true)

          headers =
            Map.new(fields, fn field ->
              [name, value] = String.split(field, ":", parts: 2)
              {String.downcase(name), String.trim(value)}
            end)

          timestamp = String.to_integer(headers["x-manifold-timestamp"])

          assert :ok =
                   SignedRequest.verify(
                     "local-test-signing-key",
                     headers["x-manifold-signature"],
                     "GET",
                     "/api/v1/deliveries/delivery-1/raw",
                     timestamp,
                     "",
                     now: timestamp,
                     request_context: [
                       installation_id: "installation-1",
                       authority: "127.0.0.1:#{port}",
                       nonce: headers["x-manifold-nonce"]
                     ]
                   )

          handler.(socket)
        after
          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        end
      end)

    source = [
      base_url: "http://127.0.0.1:#{port}",
      authority: "127.0.0.1:#{port}",
      installation_id: "installation-1",
      secret: "local-test-signing-key",
      req_options: [receive_timeout: 5_000]
    ]

    {source, peer}
  end

  defp read_head(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
      read_head(socket, buffer <> chunk)
    end
  end
end
