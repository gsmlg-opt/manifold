defmodule Manifold.Outbound.Provider.SMTPTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.Provider.Error, as: ConnectorError
  alias Manifold.Connectors.SMTP.Fake
  alias Manifold.Connectors.SubmissionMethod
  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Provider.SMTP

  @password "smtp-password-private-sentinel"
  @message_id "<018f5f6e-3d31-7ef0-a5b6-2a3ed1647601@manifold.local>"
  @raw_message "From: Sender <sender@example.net>\r\nTo: to@example.net\r\nMessage-ID: #{@message_id}\r\n\r\nHello\r\n"
  @request %Provider.Request{
    provider: "smtp",
    send_method_id: "018f5f6e-3d31-7ef0-a5b6-2a3ed1647602",
    envelope: %Provider.Envelope{
      from: "Sender <sender@example.net>",
      to: ["Recipient <to@example.net>"],
      cc: ["copy@example.net"],
      bcc: ["Hidden <hidden@example.net>"],
      subject: "Hello",
      text: "Hello",
      message_id: @message_id,
      idempotency_key: "018f5f6e-3d31-7ef0-a5b6-2a3ed1647601"
    },
    raw_message: @raw_message,
    request_sha256: "stable-request-sha"
  }

  test "connects with checked-out credentials, submits the complete envelope, and always quits" do
    method =
      method(self(), {:ok, %{response: "250 queued\r\nprivate-server-extra-response"}})

    assert {:ok,
            %Provider.Submission{
              provider_message_id: provider_message_id,
              metadata: %{response: "250 queued"}
            }} = SMTP.submit([submission_method: method, transport: Fake], @request)

    assert provider_message_id == stable_provider_id(@message_id)

    assert_receive {:smtp_fake_connect,
                    %{
                      host: "smtp.example.net",
                      port: 587,
                      tls_mode: "starttls",
                      username: "sender@example.net",
                      password: @password
                    }}

    assert_receive {:smtp_fake_submit,
                    %{
                      envelope_from: "sender@example.net",
                      recipients: [
                        "to@example.net",
                        "copy@example.net",
                        "hidden@example.net"
                      ],
                      raw_message: @raw_message
                    }}

    assert_receive :smtp_fake_quit
  end

  test "maps connector failures without leaking connector replies, message bytes, or password" do
    cases = [
      {:temporary, :timeout, :transient, "timeout"},
      {:permanent, :recipient_rejected, :permanent, "recipient_rejected"},
      {:reconnect, :auth_failed, :permanent, "auth_failed"},
      {:uncertain, :acceptance_unknown, :uncertain, "acceptance_unknown"}
    ]

    Enum.each(cases, fn {connector_class, connector_code, outbound_class, outbound_code} ->
      connector_error = %ConnectorError{
        class: connector_class,
        code: connector_code,
        message: "private server reply\r\n#{@password}\r\n#{@raw_message}"
      }

      method = method(self(), {:error, connector_error})

      assert {:error, %Provider.Error{class: ^outbound_class, code: ^outbound_code} = error} =
               SMTP.submit([submission_method: method, transport: Fake], @request)

      refute inspect(error) =~ "private server reply"
      refute inspect(error) =~ @password
      refute inspect(error) =~ @raw_message
      assert_receive :smtp_fake_quit
    end)
  end

  test "maps connect and authentication errors and cannot quit a connection that was not opened" do
    connector_error = %ConnectorError{
      class: :reconnect,
      code: :auth_failed,
      message: "private auth server reply #{@password}"
    }

    method =
      method(self(), {:ok, %{response: "unused"}}, connect_result: {:error, connector_error})

    assert {:error, %Provider.Error{class: :permanent, code: "auth_failed"} = error} =
             SMTP.submit([submission_method: method, transport: Fake], @request)

    refute inspect(error) =~ @password
    refute_receive :smtp_fake_submit
    refute_receive :smtp_fake_quit
  end

  test "ignores QUIT cleanup failures after definitive acceptance" do
    method = method(self(), {:ok, %{response: "250 queued"}}, quit_result: :raise)

    assert {:ok, %Provider.Submission{provider_message_id: provider_message_id}} =
             SMTP.submit([submission_method: method, transport: Fake], @request)

    assert provider_message_id == stable_provider_id(@message_id)
    assert_receive :smtp_fake_quit
    assert_receive :smtp_fake_quit_failure
  end

  test "rejects an unvalidated RFC Message-ID before connecting" do
    method = method(self(), {:ok, %{response: "unused"}})

    invalid_request = %{
      @request
      | envelope: %{@request.envelope | message_id: "not-a-message-id"}
    }

    assert {:error, %Provider.Error{class: :permanent, code: "invalid_message_id"}} =
             SMTP.submit([submission_method: method, transport: Fake], invalid_request)

    mismatched_raw = %{
      @request
      | raw_message: String.replace(@raw_message, @message_id, "<other@example.net>")
    }

    assert {:error, %Provider.Error{class: :permanent, code: "invalid_message_id"}} =
             SMTP.submit([submission_method: method, transport: Fake], mismatched_raw)

    injected_recipient = %{
      @request
      | envelope: %{
          @request.envelope
          | bcc: ["hidden@example.net\r\nRCPT TO:<attacker@example.net>"]
        }
    }

    assert {:error, %Provider.Error{class: :permanent, code: "invalid_envelope_address"}} =
             SMTP.submit([submission_method: method, transport: Fake], injected_recipient)

    refute_receive {:smtp_fake_connect, _settings}
  end

  defp method(event_pid, submit_result, opts \\ []) do
    %SubmissionMethod{
      id: @request.send_method_id,
      account_id: "018f5f6e-3d31-7ef0-a5b6-2a3ed1647603",
      kind: "smtp",
      email_address: "sender@example.net",
      credential: {:password, @password},
      config: %{
        host: "smtp.example.net",
        port: 587,
        tls_mode: "starttls",
        username: "sender@example.net",
        event_pid: event_pid,
        submit_result: submit_result,
        connect_result: Keyword.get(opts, :connect_result, :ok),
        quit_result: Keyword.get(opts, :quit_result, :ok)
      }
    }
  end

  defp stable_provider_id(message_id) do
    digest = :crypto.hash(:sha256, message_id) |> Base.url_encode64(padding: false)
    "smtp-#{digest}"
  end
end
