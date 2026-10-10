defmodule Manifold.Connectors.DAV.WriteTest do
  use ExUnit.Case, async: true
  alias Manifold.Connectors.DAV.{Client, Transport}
  @url "https://contacts.icloud.com/book/stable.vcf"
  @credentials %{apple_id: "test@icloud.com", app_password: "test-password"}

  test "real HTTP PUT sends the complete body with conditional creation" do
    body = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:stable\r\nFN:测试\r\nEND:VCARD\r\n"

    {url, peer} =
      wire_server(
        "HTTP/1.1 201 Created\r\nETag: \"created\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )

    transport = fn method, _, headers, payload ->
      Transport.request(method, url, headers, payload)
    end

    assert {:ok, %{etag: "\"created\""}} =
             Client.put_resource(@url, @credentials, "contacts", body, :create,
               transport: transport
             )

    {headers, payload} = Task.await(peer)
    assert headers =~ "PUT /stable.vcf HTTP/1.1"
    assert String.downcase(headers) =~ "if-none-match: *"
    assert String.downcase(headers) =~ "content-type: text/vcard; charset=utf-8"
    assert payload == body
  end

  test "real HTTP DELETE and lost PUT responses preserve outcome classification" do
    {url, peer} =
      wire_server("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

    transport = fn method, _, headers, payload ->
      Transport.request(method, url, headers, payload)
    end

    assert {:ok, :deleted} =
             Client.delete_resource(@url, @credentials, "\"base\"", transport: transport)

    {headers, ""} = Task.await(peer)
    assert headers =~ "DELETE /stable.vcf HTTP/1.1"
    assert String.downcase(headers) =~ "if-match: \"base\""

    {url, peer} = wire_server("")

    transport = fn method, _, headers, payload ->
      Transport.request(method, url, headers, payload)
    end

    assert {:error, :outcome_unknown} =
             Client.put_resource(@url, @credentials, "contacts", "complete payload", :create,
               transport: transport
             )

    assert {_, "complete payload"} = Task.await(peer)
  end

  test "create and update use conditional headers and correct media type" do
    caller = self()

    transport = fn method, url, headers, body ->
      send(caller, {method, url, Map.new(headers), body})
      {:ok, %{status: 201, headers: [{"etag", "\"new\""}], body: ""}}
    end

    assert {:ok, %{etag: "\"new\""}} =
             Client.put_resource(@url, @credentials, "contacts", "card", :create,
               transport: transport
             )

    assert_received {:put, @url, headers, "card"}
    assert headers["if-none-match"] == "*"
    assert headers["content-type"] == "text/vcard; charset=utf-8"
    refute Map.has_key?(headers, "if-match")

    assert {:ok, _} =
             Client.put_resource(@url, @credentials, "calendars", "ics", "\"base\"",
               transport: transport
             )

    assert_received {:put, @url, headers, "ics"}
    assert headers["if-match"] == "\"base\""
    assert headers["content-type"] == "text/calendar; charset=utf-8"
  end

  test "delete is conditional and weak or absent ETags never dispatch" do
    caller = self()

    transport = fn method, url, headers, body ->
      send(caller, {method, url, Map.new(headers), body})
      {:ok, %{status: 204, headers: [], body: ""}}
    end

    assert {:error, :missing_etag} =
             Client.delete_resource(@url, @credentials, "W/\"weak\"", transport: transport)

    refute_received {:delete, _, _, _}

    assert {:ok, :deleted} =
             Client.delete_resource(@url, @credentials, "\"base\"", transport: transport)

    assert_received {:delete, @url, headers, nil}
    assert headers["if-match"] == "\"base\""
  end

  test "write redirects never replay credentials or mutations" do
    caller = self()

    transport = fn _, url, _, _ ->
      send(caller, {:called, url})

      {:ok,
       %{status: 307, headers: [{"location", "https://p01-contacts.icloud.com/new"}], body: ""}}
    end

    assert {:error, :resource_moved} =
             Client.put_resource(@url, @credentials, "contacts", "card", :create,
               transport: transport
             )

    assert_received {:called, @url}
    refute_received {:called, _}
  end

  test "conflicts, forbidden, throttling and uncertain outcomes stay distinct" do
    for {status, expected} <- [
          {412, :conflict},
          {403, :forbidden},
          {401, :unauthorized},
          {500, :outcome_unknown},
          {204, :outcome_unknown}
        ] do
      transport = fn _, _, _, _ -> {:ok, %{status: status, headers: [], body: ""}} end

      assert {:error, ^expected} =
               Client.put_resource(@url, @credentials, "contacts", "card", :create,
                 transport: transport
               )
    end

    transport = fn _, _, _, _ -> {:error, :timeout} end

    assert {:error, :outcome_unknown} =
             Client.put_resource(@url, @credentials, "contacts", "card", :create,
               transport: transport
             )

    transport = fn _, _, _, _ ->
      {:ok, %{status: 429, headers: [{"retry-after", "30"}], body: ""}}
    end

    assert {:error, {:rate_limited, 30}} =
             Client.put_resource(@url, @credentials, "contacts", "card", :create,
               transport: transport
             )
  end

  test "reconciliation reads distinguish absence and demand a strong ETag" do
    missing = fn _, _, _, _ -> {:ok, %{status: 404, headers: [], body: ""}} end
    assert {:ok, :missing} = Client.get_resource(@url, @credentials, transport: missing)

    found = fn _, _, _, _ ->
      {:ok, %{status: 200, headers: [{"etag", "\"observed\""}], body: "card"}}
    end

    assert {:ok, %{content: "card", etag: "\"observed\""}} =
             Client.get_resource(@url, @credentials, transport: found)
  end

  defp wire_server(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        request = read_request(socket, "")
        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        request
      end)

    {"http://127.0.0.1:#{port}/stable.vcf", peer}
  end

  defp read_request(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, body] ->
        length =
          case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
            [_, value] -> String.to_integer(value)
            nil -> 0
          end

        if byte_size(body) >= length do
          {headers, body}
        else
          {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
          read_request(socket, buffer <> chunk)
        end

      _ ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, buffer <> chunk)
    end
  end
end
