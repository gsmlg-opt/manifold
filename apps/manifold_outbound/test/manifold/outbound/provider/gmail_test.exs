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

  test "treats a missing thread id as acceptance uncertainty" do
    Req.Test.expect(Gmail, fn conn -> Req.Test.json(conn, %{"id" => "gmail-message-2"}) end)

    assert {:error,
            %Provider.Error{
              class: :uncertain,
              code: "invalid_response",
              message: "Gmail may have accepted the message"
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

  test "protects request semantics from Req options and deprecated redirect aliases" do
    test_pid = self()

    Req.Test.stub(Gmail, fn conn ->
      case conn.host do
        "gmail.googleapis.test" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          send(
            test_pid,
            {:origin_request, conn.method, conn.request_path,
             Plug.Conn.get_req_header(conn, "authorization"), body}
          )

          conn
          |> Plug.Conn.put_resp_header("location", "https://redirect-attacker.test/capture")
          |> Plug.Conn.put_status(302)
          |> Req.Test.json(%{"error" => %{"message" => "do not follow"}})

        "redirect-attacker.test" ->
          send(
            test_pid,
            {:redirect_request, Plug.Conn.get_req_header(conn, "authorization")}
          )

          Req.Test.json(conn, %{"id" => "stolen", "threadId" => "stolen"})
      end
    end)

    config =
      Keyword.put(@config, :req_options,
        plug: {Req.Test, Gmail},
        url: "https://redirect-attacker.test/capture",
        base_url: "https://redirect-attacker.test",
        path: "/capture",
        method: :get,
        headers: [{"authorization", "Bearer attacker-token"}],
        auth: {:bearer, "attacker-token"},
        bearer: "attacker-token",
        body: "attacker-body",
        json: %{raw: "attacker-json"},
        form: [raw: "attacker-form"],
        form_multipart: [raw: "attacker-multipart"],
        retry: :transient,
        retry_delay: fn _ -> 0 end,
        max_retries: 10,
        redirect: true,
        follow_redirects: true,
        redirect_trusted: true,
        location_trusted: true
      )

    assert {:error,
            %Provider.Error{class: :permanent, code: "request_rejected", http_status: 302}} =
             Gmail.submit(config, @request)

    expected_body = Jason.encode!(%{raw: Base.url_encode64(@raw_message, padding: false)})

    assert_received {:origin_request, "POST", "/gmail/v1/users/me/messages/send",
                     ["Bearer #{@access_token}"], ^expected_body}

    refute_received {:redirect_request, _authorization}
  end

  test "scans every Gmail 403 reason and gives insufficient scope precedence" do
    Req.Test.expect(Gmail, 3, fn conn ->
      {reasons, retry_after} =
        case Process.get(:gmail_403_failure) do
          :rate_not_first -> {~w(domainPolicy userRateLimitExceeded), "45"}
          :scope_after_rate -> {~w(rateLimitExceeded insufficientPermissions), nil}
          :other -> {~w(domainPolicy), nil}
        end

      conn =
        if retry_after,
          do: Plug.Conn.put_resp_header(conn, "retry-after", retry_after),
          else: conn

      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{
        "error" => %{"errors" => Enum.map(reasons, &%{"reason" => &1})}
      })
    end)

    Process.put(:gmail_403_failure, :rate_not_first)

    assert {:error,
            %Provider.Error{
              class: :transient,
              code: "rate_limited",
              http_status: 403,
              retry_after: 45
            }} = Gmail.submit(@config, @request)

    Process.put(:gmail_403_failure, :scope_after_rate)

    assert {:error,
            %Provider.Error{
              class: :permanent,
              code: "insufficient_scope",
              http_status: 403
            }} = Gmail.submit(@config, @request)

    Process.put(:gmail_403_failure, :other)

    assert {:error,
            %Provider.Error{
              class: :permanent,
              code: "request_rejected",
              http_status: 403
            }} = Gmail.submit(@config, @request)
  after
    Process.delete(:gmail_403_failure)
  end

  test "treats malformed successful responses as acceptance uncertainty" do
    Req.Test.expect(Gmail, 5, fn conn ->
      body =
        case Process.get(:gmail_invalid_success) do
          :missing_id -> %{"threadId" => "thread-1"}
          :empty_id -> %{"id" => "", "threadId" => "thread-1"}
          :invalid_id -> %{"id" => 123, "threadId" => "thread-1"}
          :empty_thread -> %{"id" => "message-1", "threadId" => ""}
          :invalid_thread -> %{"id" => "message-1", "threadId" => 123}
        end

      Req.Test.json(conn, body)
    end)

    for failure <- [:missing_id, :empty_id, :invalid_id, :empty_thread, :invalid_thread] do
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

  test "uses only transport-error phase evidence and defaults other failures to uncertain" do
    Req.Test.expect(Gmail, 4, fn conn ->
      reason =
        case Process.get(:gmail_transport_failure) do
          :pre -> {:manifold_transport_phase, :pre_transmission, :econnrefused}
          :post -> {:manifold_transport_phase, :post_transmission, :timeout}
          :malformed -> {:manifold_transport_phase, :pre_transmission}
          :unknown -> :timeout
        end

      tagged_transport_error(conn, reason)
    end)

    Process.put(:gmail_transport_failure, :pre)

    assert {:error,
            %Provider.Error{
              class: :transient,
              code: "transport_error",
              message: "Gmail request could not be transmitted"
            }} = Gmail.submit(@config, @request)

    Process.put(:gmail_transport_failure, :post)

    assert {:error,
            %Provider.Error{
              class: :uncertain,
              code: "acceptance_unknown",
              message: "Gmail may have accepted the message"
            }} = Gmail.submit(@config, @request)

    Process.put(:gmail_transport_failure, :malformed)

    assert {:error, %Provider.Error{class: :uncertain, code: "acceptance_unknown"}} =
             Gmail.submit(@config, @request)

    Process.put(:gmail_transport_failure, :unknown)

    old_static_marker = Keyword.put(@config, :transport_failure_phase, :pre_transmission)

    assert {:error,
            %Provider.Error{
              class: :uncertain,
              code: "acceptance_unknown",
              message: "Gmail may have accepted the message"
            }} = Gmail.submit(old_static_marker, @request)
  after
    Process.delete(:gmail_transport_failure)
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

  defp tagged_transport_error(conn, reason) do
    put_in(conn.private[:req_test_exception], %Req.TransportError{reason: reason})
  end
end
