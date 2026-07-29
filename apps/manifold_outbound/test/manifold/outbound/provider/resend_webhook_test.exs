defmodule Manifold.Outbound.Provider.ResendWebhookTest do
  use ExUnit.Case, async: true

  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Provider.Resend

  @official_secret "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
  @official_body ~s({"test": 2432232314})
  @official_headers %{
    "svix-id" => "msg_p5jXN8AQM9LWM0D4loKWxJek",
    "svix-timestamp" => "1614265330",
    "svix-signature" => "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
  }

  test "verifies the published Svix HMAC example" do
    now = DateTime.from_unix!(1_614_265_330)

    assert :ok =
             Resend.verify_signature(
               [webhook_secret: @official_secret],
               @official_headers,
               @official_body,
               now
             )
  end

  test "verifies and normalizes a recipient delivery event" do
    now = ~U[2026-07-29 06:00:00Z]

    body =
      Jason.encode!(%{
        "type" => "email.delivered",
        "created_at" => "2026-07-29T05:59:55Z",
        "data" => %{
          "email_id" => "provider-message-1",
          "to" => ["first@example.net", "second@example.net"],
          "subject" => "Project update"
        }
      })

    secret = "whsec_" <> Base.encode64("test signing key")
    headers = signed_headers(secret, "event-1", now, body)

    assert {:ok,
            %Provider.Event{
              provider_event_id: "event-1",
              provider_message_id: "provider-message-1",
              event_type: "email.delivered",
              normalized_state: "delivered",
              recipient_addresses: ["first@example.net", "second@example.net"],
              occurred_at: ~U[2026-07-29 05:59:55Z],
              metadata: %{"subject" => "Project update"}
            }} =
             Resend.verify_webhook([webhook_secret: secret], headers, body, now: now)
  end

  test "rejects modified payloads, stale timestamps, and missing headers" do
    now = ~U[2026-07-29 06:00:00Z]
    body = ~s({"type":"email.delivered","data":{"email_id":"provider-1","to":[]}})
    secret = "whsec_" <> Base.encode64("test signing key")
    headers = signed_headers(secret, "event-2", now, body)

    assert {:error, %{code: "invalid_signature"}} =
             Resend.verify_webhook([webhook_secret: secret], headers, body <> " ", now: now)

    stale = DateTime.add(now, -301, :second)
    stale_headers = signed_headers(secret, "event-3", stale, body)

    assert {:error, %{code: "stale_timestamp"}} =
             Resend.verify_webhook([webhook_secret: secret], stale_headers, body, now: now)

    assert {:error, %{code: "missing_header"}} =
             Resend.verify_webhook([webhook_secret: secret], Map.delete(headers, "svix-id"), body,
               now: now
             )
  end

  test "rejects unsupported event types after authenticating the body" do
    now = ~U[2026-07-29 06:00:00Z]

    body =
      ~s({"type":"email.opened","created_at":"2026-07-29T06:00:00Z","data":{"email_id":"p1","to":["a@example.net"]}})

    secret = "whsec_" <> Base.encode64("test signing key")
    headers = signed_headers(secret, "event-4", now, body)

    assert {:error, %{code: "unsupported_event"}} =
             Resend.verify_webhook([webhook_secret: secret], headers, body, now: now)
  end

  defp signed_headers(secret, id, timestamp, body) do
    timestamp = DateTime.to_unix(timestamp)
    "whsec_" <> encoded_key = secret
    {:ok, key} = Base.decode64(encoded_key)

    signature =
      :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{body}")
      |> Base.encode64()

    %{
      "svix-id" => id,
      "svix-timestamp" => Integer.to_string(timestamp),
      "svix-signature" => "v1," <> signature
    }
  end
end
