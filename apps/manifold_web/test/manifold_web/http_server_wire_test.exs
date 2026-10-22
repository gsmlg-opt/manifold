Code.require_file("../../../../test/support/http_wire.exs", __DIR__)

defmodule ManifoldWeb.HTTPServerWireTest do
  use Manifold.DataCase, async: false
  alias Manifold.HTTPWire, as: Wire

  @secret "whsec_" <> Base.encode64("manifold wire webhook key")

  setup do
    %{port: Wire.start_endpoint(ManifoldWeb.Endpoint, :manifold_web)}
  end

  test "serves a browser session, static bytes and HEAD over the Endpoint listener", %{port: port} do
    page = Wire.request(port, "GET", "/settings/appearance")
    assert page.status == 200
    assert page.body =~ "appearance-theme-switcher"
    assert Wire.header(page.headers, "set-cookie") =~ "_manifold_key="

    static = Wire.request(port, "GET", "/favicon.ico")
    assert static.status == 200

    assert static.body ==
             File.read!(Application.app_dir(:manifold_web, "priv/static/favicon.ico"))

    head = Wire.request(port, "HEAD", "/favicon.ico")
    assert head.status == 200
    assert head.body == ""

    assert Wire.header(head.headers, "content-length") ==
             Integer.to_string(byte_size(static.body))
  end

  test "joins LiveView with the rendered session and CSRF cookie and handles an event", %{
    port: port
  } do
    %{cookie: cookie, csrf: csrf, topic: topic, join: join} = live_page(port)
    path = "/live/websocket?" <> URI.encode_query(%{"vsn" => "2.0.0", "_csrf_token" => csrf})
    socket = Wire.websocket(port, path, cookie)
    on_exit(fn -> :gen_tcp.close(socket) end)

    Wire.send_ws(socket, ["1", "1", topic, "phx_join", join])

    assert [
             "1",
             "1",
             ^topic,
             "phx_reply",
             %{"status" => "ok", "response" => %{"rendered" => rendered}}
           ] =
             Wire.receive_ws(socket)

    assert Jason.encode!(rendered) =~ "Styx Jobs"

    Wire.send_ws(socket, ["1", "2", topic, "event", filter_event()])

    assert ["1", "2", ^topic, "phx_reply", %{"status" => "ok", "response" => response}] =
             Wire.receive_ws(socket)

    assert map_size(response["diff"]) > 0

    Wire.send_ws(socket, ["1", "3", topic, "phx_leave", %{}])
    assert ["1", "1", ^topic, "phx_close", %{}] = Wire.receive_ws(socket)
    assert ["1", "3", ^topic, "phx_reply", %{"status" => "ok"}] = Wire.receive_ws(socket)
  end

  for {label, character, bytes} <- [
        {"300 KiB escaped", "\"", 300 * 1024},
        {"5 MiB ASCII", "x", 5 * 1024 * 1024}
      ] do
    test "persists and reconnects a #{label} composer body with WebSocket content", %{
      port: port
    } do
      suffix = System.unique_integer([:positive])
      {:ok, domain} = Manifold.Accounts.create_domain(%{name: "wire-composer#{suffix}.test"})
      {:ok, mailbox} = Manifold.Accounts.create_account(domain, %{local_part: "inbox"})
      {:ok, draft} = Manifold.Outbound.create_draft(mailbox.id, %{})
      page_path = "/mail/#{mailbox.id}/drafts/#{draft.id}/edit"
      %{cookie: cookie, csrf: csrf, topic: topic, join: join} = live_page(port, page_path)
      path = "/live/websocket?" <> URI.encode_query(%{"vsn" => "2.0.0", "_csrf_token" => csrf})
      socket = Wire.websocket(port, path, cookie)
      on_exit(fn -> :gen_tcp.close(socket) end)
      Wire.send_ws(socket, ["1", "1", topic, "phx_join", join])
      assert ["1", "1", ^topic, "phx_reply", %{"status" => "ok"}] = Wire.receive_ws(socket)

      text = String.duplicate(unquote(character), unquote(bytes))
      escaped_text = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

      form =
        URI.encode_query(%{
          "draft[to]" => "wire@example.net",
          "draft[cc]" => "",
          "draft[bcc]" => "",
          "draft[subject]" => "Wire composer",
          "draft[text_body]" => text
        })

      Wire.send_ws(socket, [
        "1",
        "2",
        topic,
        "event",
        %{"type" => "form", "event" => "change-draft", "value" => form}
      ])

      assert ["1", "2", ^topic, "phx_reply", %{"status" => "ok", "response" => %{"diff" => diff}}] =
               Wire.receive_ws(socket)

      assert rendered_contains?(diff, escaped_text)

      Wire.send_ws(socket, [
        "1",
        "3",
        topic,
        "event",
        %{"type" => "click", "event" => "save-current-draft", "value" => %{}}
      ])

      assert ["1", "3", ^topic, "phx_reply", %{"status" => "ok"}] = Wire.receive_ws(socket)
      assert {:ok, saved} = Manifold.Outbound.get_draft(mailbox.id, draft.id)
      assert saved.subject == "Wire composer"
      assert saved.text_body == text
      :ok = :gen_tcp.close(socket)

      %{cookie: cookie, csrf: csrf, topic: topic, join: join} = live_page(port, page_path)
      path = "/live/websocket?" <> URI.encode_query(%{"vsn" => "2.0.0", "_csrf_token" => csrf})
      reconnected = Wire.websocket(port, path, cookie)
      on_exit(fn -> :gen_tcp.close(reconnected) end)
      Wire.send_ws(reconnected, ["1", "1", topic, "phx_join", join])

      assert [
               "1",
               "1",
               ^topic,
               "phx_reply",
               %{"status" => "ok", "response" => %{"rendered" => rendered}}
             ] =
               Wire.receive_ws(reconnected)

      assert rendered_contains?(rendered, escaped_text)
    end
  end

  test "longpoll accepts the same LiveView session, join and event", %{port: port} do
    %{cookie: cookie, csrf: csrf, topic: topic, join: join} = live_page(port)
    path = "/live/longpoll?" <> URI.encode_query(%{"vsn" => "2.0.0", "_csrf_token" => csrf})
    headers = [{"cookie", cookie}, {"origin", "http://localhost"}]
    start = Wire.request(port, "GET", path, headers)
    assert start.status == 200
    assert %{"status" => 410, "token" => token, "messages" => []} = Jason.decode!(start.body)
    endpoint = ManifoldWeb.Endpoint
    salt = endpoint.config(:pubsub_server) |> Atom.to_string()

    assert {:ok, {:v1, _endpoint_id, transport, _topic}} =
             Phoenix.Token.verify(endpoint, salt, token)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Phoenix.Transports.LongPoll.Supervisor, transport)
    end)

    headers = [{"x-phoenix-longpoll-token", token} | headers]

    publish =
      Wire.request(
        port,
        "POST",
        path,
        headers,
        Jason.encode!(["1", "1", topic, "phx_join", join])
      )

    assert %{"status" => 200} = Jason.decode!(publish.body)
    poll = Wire.request(port, "GET", path, headers)
    assert %{"status" => 200, "messages" => messages} = Jason.decode!(poll.body)

    assert ["1", "1", ^topic, "phx_reply", %{"status" => "ok", "response" => %{"rendered" => _}}] =
             messages |> hd() |> decode_poll_message()

    publish =
      Wire.request(
        port,
        "POST",
        path,
        headers,
        Jason.encode!(["1", "2", topic, "event", filter_event()])
      )

    assert %{"status" => 200} = Jason.decode!(publish.body)
    poll = Wire.request(port, "GET", path, headers)
    assert %{"status" => 200, "messages" => messages} = Jason.decode!(poll.body)

    assert ["1", "2", ^topic, "phx_reply", %{"status" => "ok", "response" => %{"diff" => diff}}] =
             messages |> hd() |> decode_poll_message()

    assert map_size(diff) > 0

    publish =
      Wire.request(
        port,
        "POST",
        path,
        headers,
        Jason.encode!(["1", "3", topic, "phx_leave", %{}])
      )

    assert %{"status" => 200} = Jason.decode!(publish.body)
  end

  test "webhook signatures cover exact raw bytes and oversized requests receive 413", %{
    port: port
  } do
    old_config = Application.get_env(:manifold_outbound, :provider_config)
    Application.put_env(:manifold_outbound, :provider_config, webhook_secret: @secret)
    on_exit(fn -> restore_env(:manifold_outbound, :provider_config, old_config) end)

    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
    id = "wire-event-#{System.unique_integer([:positive])}"

    body = """
    {
      "type": "email.delivered",
      "created_at": "#{DateTime.to_iso8601(timestamp)}",
      "data": {"email_id": "#{id}", "to": ["wire@example.net"]}
    }
    """

    headers = [{"content-type", "application/json"} | signed_headers(id, timestamp, body)]
    response = Wire.request(port, "POST", "/webhooks/providers/resend", headers, body)
    assert response.status == 200
    assert response.body == ""

    tampered = Wire.request(port, "POST", "/webhooks/providers/resend", headers, body <> " ")
    assert tampered.status == 400
    assert tampered.body == "Invalid webhook"

    oversized =
      Wire.request(
        port,
        "POST",
        "/webhooks/providers/resend",
        [{"content-type", "application/json"}],
        String.duplicate("x", 1_048_577)
      )

    assert oversized.status == 413
  end

  test "accepts signed webhook bytes at the existing 1 MiB application boundary", %{port: port} do
    old_config = Application.get_env(:manifold_outbound, :provider_config)
    Application.put_env(:manifold_outbound, :provider_config, webhook_secret: @secret)
    on_exit(fn -> restore_env(:manifold_outbound, :provider_config, old_config) end)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
    id = "wire-boundary-#{System.unique_integer([:positive])}"

    payload = %{
      "type" => "email.delivered",
      "created_at" => DateTime.to_iso8601(timestamp),
      "data" => %{"email_id" => id, "to" => ["wire@example.net"]},
      "padding" => ""
    }

    padding = String.duplicate("x", 1_048_576 - byte_size(Jason.encode!(payload)))
    body = payload |> Map.put("padding", padding) |> Jason.encode!()
    assert byte_size(body) == 1_048_576
    headers = [{"content-type", "application/json"} | signed_headers(id, timestamp, body)]
    response = Wire.request(port, "POST", "/webhooks/providers/resend", headers, body)
    assert response.status == 200
    assert response.body == ""
  end

  defp live_page(port, page_path \\ "/jobs") do
    page = Wire.request(port, "GET", page_path)
    assert page.status == 200
    [cookie | _] = Wire.header(page.headers, "set-cookie") |> String.split(";")
    html = LazyHTML.from_document(page.body)

    csrf =
      html |> LazyHTML.query("meta[name=csrf-token]") |> LazyHTML.attribute("content") |> hd()

    root = LazyHTML.query(html, "[data-phx-main]")
    id = root |> LazyHTML.attribute("id") |> hd()
    session = root |> LazyHTML.attribute("data-phx-session") |> hd()
    static = root |> LazyHTML.attribute("data-phx-static") |> List.first()

    %{
      cookie: cookie,
      csrf: csrf,
      topic: "lv:" <> id,
      join: %{
        "url" => "http://localhost" <> page_path,
        "params" => %{"_csrf_token" => csrf, "_mounts" => 0, "_mount_attempts" => 0},
        "session" => session,
        "static" => static
      }
    }
  end

  defp rendered_contains?(value, expected) when is_map(value),
    do: Enum.any?(value, fn {_key, child} -> rendered_contains?(child, expected) end)

  defp rendered_contains?(value, expected) when is_list(value),
    do: Enum.any?(value, &rendered_contains?(&1, expected))

  defp rendered_contains?(value, expected), do: value == expected

  defp filter_event,
    do: %{"type" => "form", "event" => "filter", "value" => "state=completed&queue="}

  defp decode_poll_message(message) when is_binary(message), do: Jason.decode!(message)
  defp decode_poll_message(message), do: message

  defp signed_headers(id, timestamp, body) do
    "whsec_" <> encoded = @secret
    key = Base.decode64!(encoded)
    timestamp = timestamp |> DateTime.to_unix() |> Integer.to_string()
    signature = :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{body}") |> Base.encode64()
    [{"svix-id", id}, {"svix-timestamp", timestamp}, {"svix-signature", "v1," <> signature}]
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
