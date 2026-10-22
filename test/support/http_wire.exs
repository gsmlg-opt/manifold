unless Code.ensure_loaded?(Manifold.HTTPWire) do
  defmodule Manifold.HTTPWire do
    @moduledoc false
    import ExUnit.Assertions

    def start_endpoint(endpoint, otp_app) do
      config = Application.fetch_env!(otp_app, endpoint)
      adapter = Keyword.fetch!(config, :adapter)
      assert adapter == Gaoxy.PhoenixAdapter

      config =
        Keyword.merge(config,
          otp_app: otp_app,
          server: true,
          http: Keyword.merge(Keyword.get(config, :http, []), ip: {127, 0, 0, 1}, port: 0)
        )

      for spec <- adapter.child_specs(endpoint, config) do
        ExUnit.Callbacks.start_supervised!(spec)
      end

      assert {:ok, {{127, 0, 0, 1}, port}} = adapter.server_info(endpoint, :http)
      assert endpoint.server_info(:http) == {:ok, {{127, 0, 0, 1}, port}}
      port
    end

    def connect(port) do
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)
      socket
    end

    def request(port, method, path, headers \\ [], body \\ "") do
      socket = connect(port)

      try do
        send_request(socket, method, path, headers, body)
        response(socket, method)
      after
        :gen_tcp.close(socket)
      end
    end

    def send_request(socket, method, path, headers \\ [], body \\ "") do
      headers = [{"host", "localhost"}, {"connection", "close"}] ++ headers
      headers = if body == "", do: headers, else: headers ++ [{"content-length", byte_size(body)}]
      lines = Enum.map(headers, fn {key, value} -> [key, ": ", to_string(value), "\r\n"] end)
      :ok = :gen_tcp.send(socket, [method, " ", path, " HTTP/1.1\r\n", lines, "\r\n", body])
    end

    def response(socket, method \\ "GET") do
      {status, headers} = response_head(socket)

      body =
        cond do
          method == "HEAD" or status in [101, 204, 304] -> ""
          header(headers, "transfer-encoding") == "chunked" -> chunks(socket, [])
          header(headers, "content-length") == "0" -> ""
          length = header(headers, "content-length") -> recv(socket, String.to_integer(length))
          true -> until_closed(socket, [])
        end

      %{status: status, headers: headers, body: body}
    end

    def response_head(socket) do
      :ok = :inet.setopts(socket, packet: :line)
      status_line = recv(socket, 0)
      [_, status | _] = String.split(status_line, " ")
      headers = headers(socket, [])
      :ok = :inet.setopts(socket, packet: :raw)
      {String.to_integer(status), headers}
    end

    def header(headers, name),
      do: headers |> Enum.find_value(fn {k, v} -> if k == name, do: v end)

    def websocket(port, path, cookie) do
      socket = connect(port)
      key = Base.encode64(:crypto.strong_rand_bytes(16))

      :ok =
        :gen_tcp.send(socket, [
          "GET ",
          path,
          " HTTP/1.1\r\nHost: localhost\r\nOrigin: http://localhost\r\n",
          "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n",
          "Sec-WebSocket-Key: ",
          key,
          "\r\nCookie: ",
          cookie,
          "\r\n\r\n"
        ])

      assert {101, headers} = response_head(socket)

      expected =
        :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

      assert header(headers, "sec-websocket-accept") == expected
      socket
    end

    def send_ws(socket, value) do
      payload = Jason.encode!(value)
      mask = :crypto.strong_rand_bytes(4)

      size = byte_size(payload)
      mask_bytes = mask |> :binary.copy(div(size + 3, 4)) |> binary_part(0, size)
      masked = :crypto.exor(payload, mask_bytes)

      length =
        cond do
          size < 126 -> <<1::1, size::7>>
          size <= 65_535 -> <<1::1, 126::7, size::16>>
          true -> <<1::1, 127::7, size::64>>
        end

      :ok = :gen_tcp.send(socket, [<<0x81>>, length, mask, masked])
    end

    def receive_ws(socket) do
      <<1::1, 0::3, opcode::4, 0::1, length::7>> = recv(socket, 2)

      length =
        case length do
          126 -> :binary.decode_unsigned(recv(socket, 2))
          127 -> :binary.decode_unsigned(recv(socket, 8))
          other -> other
        end

      payload = recv(socket, length)

      case opcode do
        1 ->
          Jason.decode!(payload)

        8 ->
          <<code::16, reason::binary>> = payload
          flunk("expected WebSocket text, received close #{code}: #{inspect(reason)}")

        other ->
          flunk("expected WebSocket text, received opcode #{other}")
      end
    end

    defp headers(socket, acc) do
      case recv(socket, 0) do
        "\r\n" ->
          Enum.reverse(acc)

        line ->
          [key, value] = String.split(String.trim_trailing(line), ":", parts: 2)
          headers(socket, [{String.downcase(key), String.trim(value)} | acc])
      end
    end

    defp chunks(socket, acc) do
      :ok = :inet.setopts(socket, packet: :line)

      size =
        socket |> recv(0) |> String.trim() |> String.split(";") |> hd() |> String.to_integer(16)

      :ok = :inet.setopts(socket, packet: :raw)

      if size == 0 do
        assert recv(socket, 2) == "\r\n"
        acc |> Enum.reverse() |> IO.iodata_to_binary()
      else
        data = recv(socket, size)
        assert recv(socket, 2) == "\r\n"
        chunks(socket, [data | acc])
      end
    end

    defp until_closed(socket, acc) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> until_closed(socket, [data | acc])
        {:error, :closed} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      end
    end

    defp recv(socket, length) do
      {:ok, data} = :gen_tcp.recv(socket, length, 5_000)
      data
    end
  end
end
