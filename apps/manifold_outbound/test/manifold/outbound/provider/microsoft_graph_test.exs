defmodule Manifold.Outbound.Provider.MicrosoftGraphTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Provider.MicrosoftGraph

  @access_token "microsoft-token-private-sentinel"
  @raw_message "From: inbox@example.test\r\nTo: person@example.net\r\n\r\nHello, Graph!\r\n"
  @config [
    access_token: @access_token,
    base_url: "https://graph.microsoft.test",
    req_options: [plug: {Req.Test, MicrosoftGraph}]
  ]
  @request %Provider.Request{
    provider: "microsoft",
    send_method_id: "018f5f6e-3d31-7ef0-a5b6-2a3ed1647602",
    envelope: %Provider.Envelope{
      from: "inbox@example.test",
      to: ["person@example.net"],
      cc: [],
      bcc: [],
      subject: "Hello",
      text: "Hello, Graph!",
      idempotency_key: "018f5f6e-3d31-7ef0-a5b6-2a3ed1647601"
    },
    raw_message: @raw_message,
    request_sha256: "stable-request-sha"
  }
  @provider_telemetry_events [
    [:manifold, :outbound, :provider, :microsoft_graph, :stop],
    [:manifold, :outbound, :submit, :stop],
    [:finch, :request, :start],
    [:finch, :request, :stop],
    [:finch, :request, :exception]
  ]

  setup context do
    Req.Test.verify_on_exit!(context)
    :ok
  end

  test "posts the exact base64 MIME message and accepts only a 202 response" do
    Req.Test.expect(MicrosoftGraph, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/me/sendMail"
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@access_token}"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["text/plain"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == Base.encode64(@raw_message)

      conn
      |> Plug.Conn.put_resp_header("request-id", "graph-request-1")
      |> Plug.Conn.put_resp_header("client-request-id", "graph-client-1")
      |> Plug.Conn.send_resp(202, "")
    end)

    assert Provider.adapter("microsoft") == {:ok, MicrosoftGraph}

    assert {:ok,
            %Provider.Submission{
              provider_message_id: nil,
              metadata: %{
                "request_id" => "graph-request-1",
                "client_request_id" => "graph-client-1"
              }
            }} = MicrosoftGraph.submit(@config, @request)
  end

  test "retains only single bounded safe diagnostic request IDs" do
    response_secret = "diagnostic-response-private-sentinel"
    valid_128 = String.duplicate("a", 128)

    Req.Test.expect(MicrosoftGraph, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("request-id", valid_128)
      |> Plug.Conn.put_resp_header("client-request-id", "graph.client:1_safe")
      |> Plug.Conn.put_resp_header("x-private-diagnostic", response_secret)
      |> Plug.Conn.send_resp(202, response_secret)
    end)

    assert {:ok,
            %Provider.Submission{
              provider_message_id: nil,
              metadata: %{
                "request_id" => ^valid_128,
                "client_request_id" => "graph.client:1_safe"
              }
            } = submission} = secure_submit(@config, response_secret)

    refute inspect(submission) =~ response_secret
    refute inspect(submission) =~ @request.envelope.idempotency_key

    Req.Test.expect(MicrosoftGraph, fn conn ->
      conn
      |> Plug.Conn.prepend_resp_headers([
        {"request-id", "ambiguous-request-1"},
        {"request-id", "ambiguous-request-2"}
      ])
      |> Plug.Conn.put_resp_header("client-request-id", "valid-client-id")
      |> Plug.Conn.send_resp(202, response_secret)
    end)

    assert {:ok,
            %Provider.Submission{
              provider_message_id: nil,
              metadata: %{"client_request_id" => "valid-client-id"}
            }} = secure_submit(@config, response_secret)

    Req.Test.expect(MicrosoftGraph, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("request-id", String.duplicate("b", 129))
      |> Plug.Conn.put_resp_header("client-request-id", "unsafe client id")
      |> Plug.Conn.send_resp(202, response_secret)
    end)

    assert {:ok, %Provider.Submission{provider_message_id: nil, metadata: %{}}} =
             secure_submit(@config, response_secret)
  end

  test "classifies numeric and HTTP-date rate limits as transient" do
    numeric_secret = "numeric-rate-private-sentinel"
    expect_graph_error(429, "TooManyRequests", numeric_secret, retry_after: "75")

    assert {:error,
            %Provider.Error{
              class: :transient,
              code: "rate_limited",
              retry_after: 75,
              http_status: 429
            }} = secure_submit(@config, numeric_secret)

    date_secret = "date-rate-private-sentinel"
    retry_at = DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.truncate(:second)

    expect_graph_error(429, "TooManyRequests", date_secret,
      retry_after: Req.Utils.format_http_date(retry_at)
    )

    assert {:error,
            %Provider.Error{
              class: :transient,
              code: "rate_limited",
              retry_after: retry_after,
              http_status: 429
            }} = secure_submit(@config, date_secret)

    assert retry_after in 110..120
  end

  test "uses only explicit pre-transmission evidence for retryable transport failures" do
    cases = [
      {{:manifold_transport_phase, :pre_transmission, :econnrefused}, :transient,
       "transport_error", "Microsoft request could not be transmitted"},
      {{:manifold_transport_phase, :post_transmission, :timeout}, :uncertain,
       "acceptance_unknown", "Microsoft may have accepted the message"},
      {:timeout, :uncertain, "acceptance_unknown", "Microsoft may have accepted the message"}
    ]

    for {reason, expected_class, expected_code, expected_message} <- cases do
      Req.Test.expect(MicrosoftGraph, fn conn -> tagged_transport_error(conn, reason) end)

      assert {:error,
              %Provider.Error{
                class: ^expected_class,
                code: ^expected_code,
                message: ^expected_message
              }} = secure_submit(@config, "transport-response-private-sentinel")
    end

    Req.Test.expect(MicrosoftGraph, fn conn ->
      put_in(conn.private[:req_test_exception], RuntimeError.exception("unknown-private-failure"))
    end)

    assert {:error,
            %Provider.Error{
              class: :uncertain,
              code: "acceptance_unknown",
              message: "Microsoft may have accepted the message"
            }} = secure_submit(@config, "unknown-private-failure")
  end

  test "treats server responses as acceptance uncertainty" do
    for status <- [500, 502, 503, 504] do
      secret = "server-#{status}-private-sentinel"
      expect_graph_error(status, "InternalServerError", secret)

      assert {:error,
              %Provider.Error{
                class: :uncertain,
                code: "acceptance_unknown",
                message: "Microsoft may have accepted the message",
                http_status: ^status
              }} = secure_submit(@config, secret)
    end
  end

  test "treats non-202 success responses as invalid acceptance responses" do
    for status <- [200, 201, 204, 206] do
      secret = "success-#{status}-private-sentinel"
      expect_graph_error(status, "UnexpectedSuccess", secret)

      assert {:error,
              %Provider.Error{
                class: :uncertain,
                code: "invalid_response",
                message: "Microsoft may have accepted the message",
                http_status: ^status
              }} = secure_submit(@config, secret)
    end
  end

  test "requires reconnect for 401 and InvalidAuthenticationToken responses" do
    cases = [
      {401, %{"error" => %{"code" => "AnyAuthenticationFailure"}}},
      {400,
       %{
         "error" => %{
           "code" => "BadRequest",
           "innerError" => %{"code" => "inVALidAuthenticationTOKEN"}
         }
       }}
    ]

    for {status, body} <- cases do
      secret = "auth-#{status}-#{System.unique_integer([:positive])}-private-sentinel"
      expect_graph_body(status, put_in(body, ["error", "message"], secret))

      assert {:error,
              %Provider.Error{
                class: :permanent,
                code: "reconnect_required",
                http_status: ^status
              }} = secure_submit(@config, secret)
    end
  end

  test "classifies missing Microsoft send permission as insufficient scope" do
    cases = [
      %{"error" => %{"code" => "Authorization_RequestDenied"}},
      %{
        "error" => %{
          "code" => "Forbidden",
          "innerError" => %{"code" => "insufficient_scope"}
        }
      }
    ]

    for body <- cases do
      secret = "scope-#{System.unique_integer([:positive])}-private-sentinel"
      expect_graph_body(403, put_in(body, ["error", "message"], secret))

      assert {:error,
              %Provider.Error{
                class: :permanent,
                code: "insufficient_scope",
                http_status: 403
              }} = secure_submit(@config, secret)
    end
  end

  test "classifies access-denied and tenant policy responses as policy rejection" do
    for code <- ["ErrorAccessDenied", "MailboxAccessDenied", "TenantPolicyRejected"] do
      secret = "policy-#{code}-private-sentinel"
      expect_graph_error(403, code, secret)

      assert {:error,
              %Provider.Error{
                class: :permanent,
                code: "policy_rejected",
                http_status: 403
              }} = secure_submit(@config, secret)
    end
  end

  test "classifies invalid MIME, recipient, parameter, and other definite 4xx responses" do
    cases = [
      {400, "ErrorInvalidMimeContent"},
      {400, "ErrorInvalidRecipients"},
      {400, "ErrorInvalidParameter"},
      {404, "ErrorItemNotFound"},
      {409, "Conflict"},
      {422, "UnprocessableEntity"}
    ]

    for {status, code} <- cases do
      secret = "client-#{status}-#{code}-private-sentinel"
      expect_graph_error(status, code, secret)

      assert {:error,
              %Provider.Error{
                class: :permanent,
                code: "request_rejected",
                http_status: ^status
              }} = secure_submit(@config, secret)
    end
  end

  test "rejects a missing access token without making a request" do
    secret = "missing-token-private-sentinel"
    config = Keyword.delete(@config, :access_token)

    assert {:error,
            %Provider.Error{
              class: :permanent,
              code: "provider_not_configured",
              http_status: nil,
              retry_after: nil
            }} = secure_submit(config, secret)

    blank_config = Keyword.put(@config, :access_token, "")

    assert {:error, %Provider.Error{class: :permanent, code: "provider_not_configured"}} =
             secure_submit(blank_config, secret)
  end

  test "ignores hostile Req semantics and never follows a bearer-authenticated redirect" do
    test_pid = self()
    response_secret = "redirect-response-private-sentinel"

    Req.Test.stub(MicrosoftGraph, fn conn ->
      case conn.host do
        "graph.microsoft.test" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          send(
            test_pid,
            {:origin_request, conn.method, conn.request_path,
             Plug.Conn.get_req_header(conn, "authorization"),
             Plug.Conn.get_req_header(conn, "content-type"), body}
          )

          conn
          |> Plug.Conn.put_resp_header("location", "https://redirect-attacker.test/capture")
          |> Plug.Conn.put_status(302)
          |> Req.Test.json(%{"error" => %{"message" => response_secret}})

        "redirect-attacker.test" ->
          send(
            test_pid,
            {:redirect_request, Plug.Conn.get_req_header(conn, "authorization")}
          )

          Plug.Conn.send_resp(conn, 202, "")
      end
    end)

    config =
      Keyword.put(@config, :req_options,
        plug: {Req.Test, MicrosoftGraph},
        receive_timeout: 2_000,
        connect_options: [timeout: 500, hostname: "redirect-attacker.test"],
        url: "https://redirect-attacker.test/capture",
        base_url: "https://redirect-attacker.test",
        path: "/capture",
        method: :get,
        headers: [
          {"authorization", "Bearer attacker-token"},
          {"content-type", "application/json"}
        ],
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
             secure_submit(config, response_secret)

    assert_received {:origin_request, "POST", "/me/sendMail", ["Bearer #{@access_token}"],
                     ["text/plain"], encoded_body}

    assert encoded_body == Base.encode64(@raw_message)
    refute_received {:redirect_request, _authorization}
  end

  test "rejects untrusted or malformed Microsoft endpoints before exposing request secrets" do
    invalid_base_urls = [
      "http://graph.microsoft.invalid/v1.0",
      "https://169.254.169.254:1/latest/meta-data",
      "https://graph.microsoft.com.attacker.test/v1.0",
      "https://graph.microsoft.invalid:444/v1.0",
      "https://attacker@graph.microsoft.invalid/v1.0",
      "https://graph.microsoft.invalid/v1.0?next=https://attacker.test",
      "https://graph.microsoft.invalid/v1.0#attacker",
      "https://graph.microsoft.invalid/v1.0/%2e%2e/beta",
      "https://graph.microsoft.invalid/v1.0//beta",
      "not a URI"
    ]

    for base_url <- invalid_base_urls do
      config = [access_token: @access_token, base_url: base_url]

      assert {:error,
              %Provider.Error{
                class: :permanent,
                code: "invalid_config",
                message: "Microsoft Graph endpoint is invalid"
              }} = secure_submit(config, "endpoint-private-sentinel")
    end
  end

  test "permits a non-production HTTPS authority only through the owned Req.Test plug" do
    Req.Test.expect(MicrosoftGraph, fn conn ->
      assert conn.host == "graph.microsoft.test"
      assert conn.request_path == "/v1.0/me/sendMail"
      Plug.Conn.send_resp(conn, 202, "")
    end)

    config = Keyword.put(@config, :base_url, "https://graph.microsoft.test/v1.0")

    assert {:ok, %Provider.Submission{provider_message_id: nil}} =
             secure_submit(config, "test-endpoint-private-sentinel")
  end

  test "rejects invalid timeout options safely before transport" do
    invalid_options = [
      [:not_a_keyword],
      [receive_timeout: -1],
      [receive_timeout: 0],
      [receive_timeout: "5000"],
      [receive_timeout: :infinity],
      [receive_timeout: 120_001],
      [pool_timeout: -1],
      [pool_timeout: 0],
      [pool_timeout: "5000"],
      [pool_timeout: :infinity],
      [pool_timeout: 120_001],
      [connect_options: [timeout: -1]],
      [connect_options: [timeout: 0]],
      [connect_options: [timeout: "5000"]],
      [connect_options: [timeout: :infinity]],
      [connect_options: [timeout: 120_001]],
      [connect_options: "5000"]
    ]

    for req_options <- invalid_options do
      config = Keyword.put(@config, :req_options, req_options)

      assert {:error,
              %Provider.Error{
                class: :permanent,
                code: "invalid_config",
                message: "Microsoft Graph transport options are invalid"
              }} = secure_submit(config, "timeout-private-sentinel")
    end
  end

  test "rejects non-keyword configuration lists without raising" do
    config = [{:access_token, @access_token}, :not_a_keyword]

    assert {:error,
            %Provider.Error{
              class: :permanent,
              code: "invalid_config",
              message: "Microsoft Graph transport options are invalid"
            }} = secure_submit(config, "config-private-sentinel")
  end

  test "production transport does not emit bearer or MIME bytes in Finch telemetry" do
    handler_id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:finch, :request, :start],
          [:finch, :request, :stop],
          [:finch, :request, :exception]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:finch_transport_telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    config = [
      access_token: @access_token,
      base_url: "https://graph.microsoft.invalid/v1.0",
      req_options: [receive_timeout: 100, connect_options: [timeout: 100]]
    ]

    log =
      try do
        capture_log(fn ->
          assert {:error, %Provider.Error{class: :transient, code: "transport_error"}} =
                   MicrosoftGraph.submit(config, @request)
        end)
      after
        :telemetry.detach(handler_id)
      end

    telemetry = drain_finch_telemetry([])

    assert telemetry == []

    for inspected <- [log, inspect(telemetry)] do
      refute inspected =~ @access_token
      refute inspected =~ @raw_message
      refute inspected =~ Base.encode64(@raw_message)
    end
  end

  defp expect_graph_error(status, code, secret, opts \\ []) do
    expect_graph_body(
      status,
      %{
        "error" => %{
          "code" => code,
          "message" => secret,
          "innerError" => %{"private" => [secret, @access_token, @raw_message]}
        }
      },
      opts
    )
  end

  defp expect_graph_body(status, body, opts \\ []) do
    Req.Test.expect(MicrosoftGraph, fn conn ->
      conn =
        case Keyword.get(opts, :retry_after) do
          nil -> conn
          value -> Plug.Conn.put_resp_header(conn, "retry-after", value)
        end

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  defp secure_submit(config, response_secret) do
    telemetry_ref = make_ref()
    handler_id = {__MODULE__, self(), telemetry_ref}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        @provider_telemetry_events,
        fn event, measurements, metadata, {pid, ref} ->
          send(pid, {:graph_provider_telemetry, ref, event, measurements, metadata})
        end,
        {test_pid, telemetry_ref}
      )

    log =
      try do
        capture_log(fn ->
          send(
            test_pid,
            {:graph_submission_result, telemetry_ref, MicrosoftGraph.submit(config, @request)}
          )
        end)
      after
        :telemetry.detach(handler_id)
      end

    assert_receive {:graph_submission_result, ^telemetry_ref, result}
    telemetry = drain_telemetry(telemetry_ref, [])

    for inspected <- [log, inspect(result), inspect(telemetry)] do
      refute inspected =~ response_secret
      refute inspected =~ @access_token
      refute inspected =~ @raw_message
    end

    result
  end

  defp drain_telemetry(ref, entries) do
    receive do
      {:graph_provider_telemetry, ^ref, event, measurements, metadata} ->
        drain_telemetry(ref, [{event, measurements, metadata} | entries])
    after
      0 -> Enum.reverse(entries)
    end
  end

  defp drain_finch_telemetry(entries) do
    receive do
      {:finch_transport_telemetry, event, measurements, metadata} ->
        drain_finch_telemetry([{event, measurements, metadata} | entries])
    after
      0 -> Enum.reverse(entries)
    end
  end

  defp tagged_transport_error(conn, reason) do
    put_in(conn.private[:req_test_exception], %Req.TransportError{reason: reason})
  end
end
