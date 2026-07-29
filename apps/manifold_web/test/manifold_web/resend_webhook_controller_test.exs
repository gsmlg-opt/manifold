defmodule ManifoldWeb.ResendWebhookControllerTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Outbound
  alias Manifold.Outbound.Provider

  @secret "whsec_" <> Base.encode64("manifold webhook test key")

  defmodule TestProvider do
    @behaviour Manifold.Outbound.Provider

    @impl true
    def submit(config, _envelope) do
      {:ok,
       %Provider.Submission{
         provider_message_id: Keyword.fetch!(config, :provider_message_id),
         metadata: %{}
       }}
    end
  end

  setup do
    old_config = Application.get_env(:manifold_outbound, :provider_config)
    old_record_options = Application.get_env(:manifold_web, :resend_webhook_record_options)
    Application.put_env(:manifold_outbound, :provider_config, webhook_secret: @secret)
    Application.delete_env(:manifold_web, :resend_webhook_record_options)

    on_exit(fn ->
      restore_env(:manifold_outbound, :provider_config, old_config)
      restore_env(:manifold_web, :resend_webhook_record_options, old_record_options)
    end)

    :ok
  end

  test "verifies the exact raw request bytes and accepts an unmatched event", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    body = webhook_body("raw-event-1", now)
    headers = signed_headers("raw-event-1", now, body)

    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> put_signature_headers(headers)
      |> post("/webhooks/providers/resend", body)

    assert response(conn, 200) == ""
  end

  test "returns 200 when Resend retries an already persisted event", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    body = webhook_body("duplicate-message", now)
    headers = signed_headers("duplicate-event", now, body)

    assert conn |> post_webhook(body, headers) |> response(200) == ""
    assert build_conn() |> post_webhook(body, headers) |> response(200) == ""
  end

  test "returns 200 when an event is applied to a provider-accepted message", %{conn: conn} do
    provider_message_id = "processed-message"
    accepted_message_fixture(provider_message_id)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    body = webhook_body(provider_message_id, now)
    headers = signed_headers("processed-event", now, body)

    assert conn |> post_webhook(body, headers) |> response(200) == ""
  end

  test "returns 400 when the raw body does not match the signature", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    body = webhook_body("tampered-message", now)
    headers = signed_headers("tampered-event", now, body)

    assert conn
           |> post_webhook(body <> " ", headers)
           |> response(400) == "Invalid webhook"
  end

  test "returns 503 when provider event persistence fails temporarily", %{conn: conn} do
    Application.put_env(
      :manifold_web,
      :resend_webhook_record_options,
      fail_at: :after_event_before_recipient_update
    )

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    body = webhook_body("temporary-failure-message", now)
    headers = signed_headers("temporary-failure-event", now, body)

    assert conn
           |> post_webhook(body, headers)
           |> response(503) == "Webhook persistence temporarily unavailable"
  end

  test "rejects an oversized webhook before JSON parsing", %{conn: conn} do
    body = ~s({"padding":"#{String.duplicate("x", 1_048_576)}"})

    assert conn
           |> Plug.Conn.put_req_header("content-type", "application/json")
           |> post("/webhooks/providers/resend", body)
           |> response(413) == "Payload Too Large"
  end

  defp webhook_body(provider_message_id, occurred_at) do
    """
    {
      "type": "email.delivered",
      "created_at": "#{DateTime.to_iso8601(occurred_at)}",
      "data": { "email_id": "#{provider_message_id}", "to": ["recipient@example.net"] }
    }
    """
  end

  defp signed_headers(event_id, timestamp, body) do
    "whsec_" <> encoded_key = @secret
    {:ok, key} = Base.decode64(encoded_key)
    timestamp = DateTime.to_unix(timestamp) |> Integer.to_string()

    signature =
      :crypto.mac(:hmac, :sha256, key, "#{event_id}.#{timestamp}.#{body}")
      |> Base.encode64()

    %{
      "svix-id" => event_id,
      "svix-timestamp" => timestamp,
      "svix-signature" => "v1," <> signature
    }
  end

  defp put_signature_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      Plug.Conn.put_req_header(acc, name, value)
    end)
  end

  defp post_webhook(conn, body, headers) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> put_signature_headers(headers)
    |> post("/webhooks/providers/resend", body)
  end

  defp accepted_message_fixture(provider_message_id) do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "webhook#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_mailbox(domain, %{local_part: "inbox"})

    {:ok, draft} =
      Outbound.create_draft(mailbox.id, %{
        subject: "Webhook",
        text_body: "Body",
        recipients: [%{kind: "to", address: "recipient@example.net"}]
      })

    {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)

    assert :ok =
             Outbound.submit_message(queued.id,
               provider: TestProvider,
               provider_config: [provider_message_id: provider_message_id]
             )

    queued
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
