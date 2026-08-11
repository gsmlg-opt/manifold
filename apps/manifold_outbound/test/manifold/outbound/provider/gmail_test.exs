defmodule Manifold.Outbound.Provider.GmailTest do
  use ExUnit.Case, async: true

  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Provider.Gmail

  @access_token "gmail-token-private-sentinel"
  @raw_message "From: inbox@example.test\r\nTo: person@example.net\r\n\r\nHello, Gmail!\r\n"
  @config [
    access_token: @access_token,
    base_url: "https://gmail.googleapis.test",
    req_options: [plug: {Req.Test, Gmail}]
  ]
  @request %Provider.Request{
    provider: "gmail",
    send_method_id: "018f5f6e-3d31-7ef0-a5b6-2a3ed1647602",
    envelope: %Provider.Envelope{
      from: "inbox@example.test",
      to: ["person@example.net"],
      cc: [],
      bcc: [],
      subject: "Hello",
      text: "Hello, Gmail!",
      idempotency_key: "018f5f6e-3d31-7ef0-a5b6-2a3ed1647601"
    },
    raw_message: @raw_message,
    request_sha256: "stable-request-sha"
  }

  test "posts the exact base64url RFC message with bearer authorization" do
    Req.Test.expect(Gmail, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/gmail/v1/users/me/messages/send"
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@access_token}"]
      assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/json")

      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "raw" => Base.url_encode64(@raw_message, padding: false)
             }

      Req.Test.json(conn, %{"id" => "gmail-message-1", "threadId" => "gmail-thread-1"})
    end)

    assert {:ok,
            %Provider.Submission{
              provider_message_id: "gmail-message-1",
              metadata: %{thread_id: "gmail-thread-1"}
            }} = Gmail.submit(@config, @request)
  end

  test "accepts a nonempty message id when Gmail omits the thread id" do
    Req.Test.expect(Gmail, fn conn -> Req.Test.json(conn, %{"id" => "gmail-message-2"}) end)

    assert {:ok,
            %Provider.Submission{
              provider_message_id: "gmail-message-2",
              metadata: %{thread_id: nil}
            }} = Gmail.submit(@config, @request)
  end

  test "classifies authentication and authorization failures without retry" do
    Req.Test.expect(Gmail, 3, fn conn ->
      case Process.get(:gmail_failure) do
        :unauthorized ->
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"error" => %{"message" => "private-auth-response"}})

        :invalid_grant ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{
            "error" => "invalid_grant",
            "error_description" => "private-grant-response"
          })

        :insufficient_scope ->
          conn
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(%{
            "error" => %{
              "message" => "private-scope-response",
              "errors" => [%{"reason" => "insufficientPermissions"}]
            }
          })
      end
    end)

    Process.put(:gmail_failure, :unauthorized)

    assert {:error,
            %Provider.Error{
              class: :permanent,
              code: "reconnect_required",
              http_status: 401
            }} = Gmail.submit(@config, @request)

    Process.put(:gmail_failure, :invalid_grant)

    assert {:error,
            %Provider.Error{
              class: :permanent,
              code: "reconnect_required",
              http_status: 400
            }} = Gmail.submit(@config, @request)

    Process.put(:gmail_failure, :insufficient_scope)

    assert {:error,
            %Provider.Error{
              class: :permanent,
              code: "insufficient_scope",
              http_status: 403
            }} = Gmail.submit(@config, @request)
  after
    Process.delete(:gmail_failure)
  end

  test "classifies rate limits, definite client failures, and server failures" do
    Req.Test.expect(Gmail, 3, fn conn ->
      case Process.get(:gmail_failure) do
        :rate_limited ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "75")
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{"error" => %{"message" => "private-rate-response"}})

        :client_rejected ->
          conn
          |> Plug.Conn.put_status(422)
          |> Req.Test.json(%{"error" => %{"message" => "private-client-response"}})

        :server ->
          conn
          |> Plug.Conn.put_status(503)
          |> Req.Test.json(%{"error" => %{"message" => "private-server-response"}})
      end
    end)

    Process.put(:gmail_failure, :rate_limited)

    assert {:error,
            %Provider.Error{
              class: :transient,
              code: "rate_limited",
              retry_after: 75,
              http_status: 429
            }} = Gmail.submit(@config, @request)

    Process.put(:gmail_failure, :client_rejected)

    assert {:error,
            %Provider.Error{
              class: :permanent,
              code: "request_rejected",
              http_status: 422
            }} = Gmail.submit(@config, @request)

    Process.put(:gmail_failure, :server)

    assert {:error,
            %Provider.Error{
              class: :transient,
              code: "provider_unavailable",
              http_status: 503
            }} = Gmail.submit(@config, @request)
  after
    Process.delete(:gmail_failure)
  end

  test "does not retry or follow redirects even when Req options request them" do
    Req.Test.expect(Gmail, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://private-redirect.test/secret")
      |> Plug.Conn.put_status(302)
      |> Req.Test.json(%{"error" => %{"message" => "do not follow"}})
    end)

    config =
      Keyword.put(@config, :req_options, plug: {Req.Test, Gmail}, retry: true, redirect: true)

    assert {:error,
            %Provider.Error{class: :permanent, code: "request_rejected", http_status: 302}} =
             Gmail.submit(config, @request)
  end

  test "treats malformed successful responses as acceptance uncertainty" do
    Req.Test.expect(Gmail, 4, fn conn ->
      body =
        case Process.get(:gmail_invalid_success) do
          :missing_id -> %{"threadId" => "thread-1"}
          :empty_id -> %{"id" => "", "threadId" => "thread-1"}
          :empty_thread -> %{"id" => "message-1", "threadId" => ""}
          :invalid_thread -> %{"id" => "message-1", "threadId" => 123}
        end

      Req.Test.json(conn, body)
    end)

    for failure <- [:missing_id, :empty_id, :empty_thread, :invalid_thread] do
      Process.put(:gmail_invalid_success, failure)

      assert {:error,
              %Provider.Error{
                class: :uncertain,
                code: "invalid_response",
                message: "Gmail may have accepted the message"
              }} = Gmail.submit(@config, @request)
    end
  after
    Process.delete(:gmail_invalid_success)
  end

  test "uses explicit transport phase evidence and defaults unknown failures to uncertain" do
    Req.Test.expect(Gmail, 3, &Req.Test.transport_error(&1, :timeout))

    pre_transmission = Keyword.put(@config, :transport_failure_phase, :pre_transmission)

    assert {:error,
            %Provider.Error{
              class: :transient,
              code: "transport_error",
              message: "Gmail request could not be transmitted"
            }} = Gmail.submit(pre_transmission, @request)

    post_transmission = Keyword.put(@config, :transport_failure_phase, :post_transmission)

    assert {:error,
            %Provider.Error{
              class: :uncertain,
              code: "acceptance_unknown",
              message: "Gmail may have accepted the message"
            }} = Gmail.submit(post_transmission, @request)

    assert {:error,
            %Provider.Error{
              class: :uncertain,
              code: "acceptance_unknown",
              message: "Gmail may have accepted the message"
            }} = Gmail.submit(@config, @request)
  end

  test "sanitizes long malicious responses and never exposes request or token secrets" do
    response_secret = "private-response-sentinel"
    long_secret = String.duplicate(response_secret, 100)

    Req.Test.expect(Gmail, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => %{
          "message" => long_secret,
          "details" => [@access_token, @raw_message]
        }
      })
    end)

    assert {:error, %Provider.Error{} = error} = Gmail.submit(@config, @request)
    assert byte_size(error.message) <= 500
    refute inspect(error) =~ response_secret
    refute inspect(error) =~ @access_token
    refute inspect(error) =~ @raw_message
  end
end
