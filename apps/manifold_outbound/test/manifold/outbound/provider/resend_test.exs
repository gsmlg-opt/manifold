defmodule Manifold.Outbound.Provider.ResendTest do
  use ExUnit.Case, async: true

  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Provider.Resend

  @config [
    api_key: "re_test_secret",
    base_url: "https://api.resend.test",
    req_options: [plug: {Req.Test, Resend}]
  ]

  @envelope %Provider.Envelope{
    from: "Local Inbox <inbox@example.test>",
    to: ["first@example.net"],
    cc: ["copy@example.net"],
    bcc: [],
    subject: "Project update",
    text: "Message body",
    in_reply_to: "<source@example.net>",
    references: ["<root@example.net>", "<source@example.net>"],
    idempotency_key: "018f5f6e-3d31-7ef0-a5b6-2a3ed1647601"
  }

  test "submits the exact payload with provider idempotency and threading headers" do
    Req.Test.expect(Resend, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/emails"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer re_test_secret"]

      assert Plug.Conn.get_req_header(conn, "idempotency-key") == [
               @envelope.idempotency_key
             ]

      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "from" => "Local Inbox <inbox@example.test>",
               "to" => ["first@example.net"],
               "cc" => ["copy@example.net"],
               "bcc" => [],
               "subject" => "Project update",
               "text" => "Message body",
               "headers" => %{
                 "In-Reply-To" => "<source@example.net>",
                 "References" => "<root@example.net> <source@example.net>"
               }
             }

      Req.Test.json(conn, %{"id" => "resend-message-1"})
    end)

    assert {:ok,
            %Provider.Submission{
              provider_message_id: "resend-message-1",
              metadata: %{}
            }} = Resend.submit(@config, @envelope)
  end

  test "classifies retryable provider and transport failures" do
    Req.Test.expect(Resend, 3, fn conn ->
      case Process.get(:resend_failure) do
        :server -> conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"message" => "later"})
        :rate -> conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"message" => "slow down"})
        :network -> Req.Test.transport_error(conn, :timeout)
      end
    end)

    Process.put(:resend_failure, :server)
    assert {:error, %{class: :transient, code: "http_503"}} = Resend.submit(@config, @envelope)

    Process.put(:resend_failure, :rate)
    assert {:error, %{class: :transient, code: "http_429"}} = Resend.submit(@config, @envelope)

    Process.put(:resend_failure, :network)

    assert {:error, %{class: :transient, code: "transport_error"}} =
             Resend.submit(@config, @envelope)
  after
    Process.delete(:resend_failure)
  end

  test "parses Retry-After seconds from rate-limit responses" do
    Req.Test.expect(Resend, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "90")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"message" => "slow down"})
    end)

    assert {:error,
            %Provider.Error{
              class: :transient,
              code: "http_429",
              retry_after: 90
            }} = Resend.submit(@config, @envelope)
  end

  test "parses Retry-After HTTP dates from rate-limit responses" do
    retry_at = DateTime.add(DateTime.utc_now(), 120, :second)
    retry_after = Calendar.strftime(retry_at, "%a, %d %b %Y %H:%M:%S GMT")

    Req.Test.expect(Resend, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", retry_after)
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"message" => "slow down"})
    end)

    assert {:error, %Provider.Error{class: :transient, retry_after: seconds}} =
             Resend.submit(@config, @envelope)

    assert seconds in 118..120
  end

  test "distinguishes concurrent idempotency from a divergent payload" do
    Req.Test.expect(Resend, 2, fn conn ->
      {error_type, message} =
        case Process.get(:resend_conflict) do
          :concurrent -> {"concurrent_idempotent_requests", "in progress"}
          :divergent -> {"invalid_idempotent_request", "payload differs"}
        end

      conn
      |> Plug.Conn.put_status(409)
      |> Req.Test.json(%{"name" => error_type, "message" => message})
    end)

    Process.put(:resend_conflict, :concurrent)

    assert {:error, %{class: :transient, code: "concurrent_idempotent_requests"}} =
             Resend.submit(@config, @envelope)

    Process.put(:resend_conflict, :divergent)

    assert {:error, %{class: :permanent, code: "invalid_idempotent_request"}} =
             Resend.submit(@config, @envelope)
  after
    Process.delete(:resend_conflict)
  end

  test "classifies other client errors as permanent without exposing the API key" do
    Req.Test.expect(Resend, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"name" => "validation_error", "message" => "bad sender"})
    end)

    assert {:error, error} = Resend.submit(@config, @envelope)
    assert error.class == :permanent
    assert error.code == "validation_error"
    refute inspect(error) =~ "re_test_secret"
  end

  test "missing API credentials are a permanent configuration failure" do
    assert {:error,
            %Provider.Error{
              class: :permanent,
              code: "provider_not_configured"
            }} = Resend.submit([], @envelope)
  end
end
