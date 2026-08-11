defmodule Manifold.Outbound.SubmissionTest do
  use Manifold.DataCase, async: true

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, GmailScopes}

  alias Manifold.Connectors.Schema.{
    OAuthAuthorization,
    SendCredential,
    SendMethod,
    SmtpSettings
  }

  alias Manifold.Outbound
  alias Manifold.Outbound.LegacyResendFixture
  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Schema.{OutboundEvent, OutboundMessage, ProviderSubmission}
  alias Manifold.Repo

  defmodule TestProvider do
    @behaviour Manifold.Outbound.Provider

    @impl true
    def submit(config, request) do
      send(Keyword.fetch!(config, :test_pid), {:provider_submit, request, config})
      Keyword.fetch!(config, :result)
    end
  end

  defmodule TestSMTPTransport do
    def connect(settings) do
      send(self(), {:smtp_connect, settings})
      {:ok, self()}
    end

    def submit(_conn, envelope) do
      send(self(), {:smtp_submit, envelope})
      {:ok, %{response: "250 queued"}}
    end

    def quit(_conn), do: :ok
  end

  test "provider acceptance commits message and logical submission state" do
    message = queued_message_fixture()

    assert :ok =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result:
                   {:ok,
                    %Provider.Submission{
                      provider_message_id: "provider-1",
                      metadata: %{"region" => "us-east-1"}
                    }}
               ]
             )

    assert_receive {:provider_submit,
                    %Provider.Request{provider: "resend", send_method_id: nil} = request, _config}

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert request.request_sha256 == submission.request_sha256
    envelope = request.envelope
    assert envelope.subject == "Ready"
    assert envelope.to == ["person@example.net"]
    refute inspect(envelope) =~ "api_key"

    accepted = Repo.get!(OutboundMessage, message.id)
    assert accepted.state == "accepted_by_provider"
    assert %DateTime{} = accepted.accepted_at

    submission = Repo.get!(ProviderSubmission, submission.id)
    assert submission.state == "accepted"
    assert submission.provider_message_id == "provider-1"
    assert submission.attempt_count == 1
    assert submission.provider_metadata == %{"region" => "us-east-1"}

    assert Repo.get_by!(OutboundEvent,
             outbound_message_id: message.id,
             event_type: "provider_accepted"
           )
  end

  test "provider acceptance commit failure is returned as a temporary database error" do
    message = queued_message_fixture()

    assert {:error, %{class: :temporary, reason: :database_unavailable}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result:
                   {:ok,
                    %Provider.Submission{
                      provider_message_id: "provider-rollback",
                      metadata: %{}
                    }}
               ],
               fail_at: :provider_accept_commit
             )

    assert_receive {:provider_submit, _request, _config}
    assert Repo.get!(OutboundMessage, message.id).state == "submitting"

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert submission.state == "submitting"
    assert submission.provider_message_id == nil

    refute Repo.get_by(OutboundEvent,
             outbound_message_id: message.id,
             event_type: "provider_accepted"
           )
  end

  test "transient failure returns to queued and retries the byte-identical request" do
    message = queued_message_fixture()

    transient =
      {:error,
       %Provider.Error{
         class: :transient,
         code: "http_503",
         message: "later",
         http_status: 503
       }}

    assert {:error, %Provider.Error{class: :transient}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: transient]
             )

    assert_receive {:provider_submit, first_request, _config}
    assert Repo.get!(OutboundMessage, message.id).state == "queued"

    assert :ok =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result:
                   {:ok, %Provider.Submission{provider_message_id: "provider-2", metadata: %{}}}
               ]
             )

    assert_receive {:provider_submit, second_request, _config}
    assert second_request == first_request
    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).attempt_count == 2
  end

  test "terminal provider failure is persisted and is not retried" do
    message = queued_message_fixture()

    permanent =
      {:error,
       %Provider.Error{
         class: :permanent,
         code: "validation_error",
         message: "bad sender",
         http_status: 422
       }}

    assert {:error, %Provider.Error{class: :permanent}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: permanent]
             )

    assert Repo.get!(OutboundMessage, message.id).state == "failed"
    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).state == "failed"
  end

  test "provider error commit failure is returned as a temporary database error" do
    message = queued_message_fixture()

    transient =
      {:error,
       %Provider.Error{
         class: :transient,
         code: "http_503",
         message: "later",
         http_status: 503
       }}

    assert {:error, %{class: :temporary, reason: :database_unavailable}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: transient],
               fail_at: :provider_error_commit
             )

    assert_receive {:provider_submit, _request, _config}
    assert Repo.get!(OutboundMessage, message.id).state == "submitting"

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert submission.state == "submitting"
    assert submission.last_error_code == nil

    refute Repo.get_by(OutboundEvent,
             outbound_message_id: message.id,
             event_type: "submission_retryable"
           )
  end

  test "crash after provider acceptance retries with the same idempotency key" do
    message = queued_message_fixture()

    success =
      {:ok, %Provider.Submission{provider_message_id: "provider-3", metadata: %{}}}

    assert {:error, %{reason: :after_provider_accept_before_commit}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: success],
               fail_at: :after_provider_accept_before_commit
             )

    assert_receive {:provider_submit, first_request, _config}
    assert Repo.get!(OutboundMessage, message.id).state == "submitting"
    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).state == "submitting"

    assert :ok =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: success]
             )

    assert_receive {:provider_submit, second_request, _config}
    assert second_request.envelope.idempotency_key == first_request.envelope.idempotency_key
    assert second_request == first_request
  end

  test "ambiguous submission outside the idempotency window becomes uncertain" do
    message = queued_message_fixture()
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)

    message
    |> Ecto.Changeset.change(state: "submitting")
    |> Repo.update!()

    submission
    |> Ecto.Changeset.change(
      state: "submitting",
      attempt_count: 1,
      idempotency_expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
    )
    |> Repo.update!()

    assert {:error, %{reason: :submission_uncertain}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result:
                   {:ok,
                    %Provider.Submission{provider_message_id: "must-not-send", metadata: %{}}}
               ]
             )

    refute_receive {:provider_submit, _request, _config}
    assert Repo.get!(OutboundMessage, message.id).state == "submission_uncertain"
    assert Repo.get!(ProviderSubmission, submission.id).state == "uncertain"
  end

  test "Gmail dispatch checks out the snapshotted method and verifies rendered bytes" do
    %{message: message, method: method} = queued_operational_fixture("gmail")

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer gmail-access-token"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"raw" => encoded} = Jason.decode!(body)
      assert {:ok, raw} = Base.url_decode64(encoded, padding: false)
      send(self(), {:gmail_raw, raw})
      Req.Test.json(conn, %{"id" => "gmail-message-1", "threadId" => "thread-1"})
    end)

    assert :ok =
             Outbound.submit_message(message.id,
               provider_config: [
                 base_url: "https://gmail.test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               ]
             )

    assert_receive {:gmail_raw, raw}
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert submission.send_method_id == method.id
    assert submission.request_sha256 == sha256(raw)
    assert raw =~ "Message-ID: <#{message.id}@manifold.local>\r\n"

    persisted = Repo.get!(ProviderSubmission, submission.id)
    assert persisted.provider_metadata == %{"thread_id" => "thread-1"}
  end

  test "SMTP dispatch checks out password settings for the snapshotted method" do
    %{message: message, method: method} = queued_operational_fixture("smtp")

    assert :ok =
             Outbound.submit_message(message.id,
               provider_config: [transport: TestSMTPTransport]
             )

    assert_receive {:smtp_connect, settings}
    assert settings.password == "smtp-secret"
    assert_receive {:smtp_submit, envelope}

    assert envelope.raw_message |> sha256() ==
             Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).request_sha256

    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).send_method_id ==
             method.id
  end

  test "does not reroute a queued submission when its snapshot is disabled" do
    %{message: message, method: snapshot, account: account, address: address} =
      queued_operational_fixture("smtp")

    snapshot |> SendMethod.changeset(%{enabled: false}) |> Repo.update!()
    _current = insert_gmail_method!(account, address)

    assert {:error, %Provider.Error{class: :permanent, code: "send_method_required"}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute_receive {:provider_submit, _, _}
    assert Repo.get!(OutboundMessage, message.id).state == "failed"
  end

  test "provider mismatch and rendered SHA tampering fail before provider I/O" do
    %{message: mismatch_message} = queued_operational_fixture("gmail")
    mismatch = Repo.get_by!(ProviderSubmission, outbound_message_id: mismatch_message.id)
    mismatch |> Ecto.Changeset.change(provider: "smtp") |> Repo.update!()

    assert {:error, %Provider.Error{class: :permanent, code: "send_method_provider_mismatch"}} =
             Outbound.submit_message(mismatch_message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    %{message: tampered_message} = queued_operational_fixture("smtp")
    tampered = Repo.get_by!(ProviderSubmission, outbound_message_id: tampered_message.id)

    tampered
    |> Ecto.Changeset.change(request_sha256: String.duplicate("0", 64))
    |> Repo.update!()

    assert {:error, %Provider.Error{class: :permanent, code: "request_integrity_failed"}} =
             Outbound.submit_message(tampered_message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute_receive {:provider_submit, _, _}
  end

  test "disconnected and reconnect-required snapshots block submission" do
    for {status, expected_code} <- [
          {"disconnected", "account_disconnected"},
          {"reconnect_required", "reauthorization_required"}
        ] do
      %{message: message, method: method} = queued_operational_fixture("smtp")

      method
      |> SendMethod.changeset(%{status: status, enabled: false})
      |> Repo.update!()

      assert {:error, %Provider.Error{class: :permanent, code: ^expected_code}} =
               Outbound.submit_message(message.id,
                 provider: TestProvider,
                 provider_config: [test_pid: self(), result: :unused]
               )
    end

    refute_receive {:provider_submit, _, _}
  end

  test "uncertain provider result transitions atomically and is never submitted again" do
    %{message: message} = queued_operational_fixture("smtp")
    handler_id = "submission-uncertain-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :outbound, :submit, :stop],
        fn _event, _measurements, metadata, pid -> send(pid, {:submit_stop, metadata}) end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    uncertain =
      {:error,
       %Provider.Error{
         class: :uncertain,
         code: "acceptance_unknown",
         message: "provider may have accepted"
       }}

    assert {:error, %{class: :permanent, reason: :submission_uncertain}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: uncertain]
             )

    assert_receive {:provider_submit, _, _}

    assert_receive {:submit_stop,
                    %{outcome: :uncertain, outbound_message_id: outbound_message_id}}

    assert outbound_message_id == message.id
    persisted_message = Repo.get!(OutboundMessage, message.id)
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert persisted_message.state == "submission_uncertain"
    assert persisted_message.last_error_class == "uncertain"
    assert submission.state == "uncertain"
    assert submission.last_error_code == "acceptance_unknown"

    assert Repo.aggregate(
             from(event in OutboundEvent,
               where:
                 event.outbound_message_id == ^message.id and
                   event.event_type == "submission_uncertain"
             ),
             :count
           ) == 1

    assert {:error, %{class: :permanent, reason: :submission_uncertain}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute_receive {:provider_submit, _, _}
    refute_receive {:submit_stop, %{outcome: :uncertain}}
  end

  defp queued_message_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "submit#{suffix}.test"})

    {:ok, mailbox} =
      Accounts.create_account(domain, %{local_part: "inbox", name: "Local Inbox"})

    %{message: queued, method: method, submission: submission} =
      LegacyResendFixture.queue!(mailbox.id, "inbox@#{domain.normalized_domain}", %{
        subject: "Ready",
        text_body: "Body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    assert Repo.get(SendMethod, method.id) == nil

    assert {:error, %{reason: :send_method_required}} =
             Connectors.checkout_send_method(method.id, queued.sender_address)

    assert %{
             send_method_id: nil,
             provider: "resend",
             provider_rfc_message_id: nil,
             idempotency_expires_at: %DateTime{}
           } = submission

    assert submission.request_sha256 == LegacyResendFixture.request_sha256(queued)
    queued
  end

  defp queued_operational_fixture(kind) do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "dispatch#{suffix}.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "sender", name: "Sender"})
    address = "sender@#{domain.normalized_domain}"

    method =
      case kind do
        "gmail" -> insert_gmail_method!(account, address)
        "smtp" -> insert_smtp_method!(account, address)
      end

    {:ok, draft} =
      Outbound.create_draft(account.id, %{
        subject: "Operational",
        text_body: "Stable body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    {:ok, message} = Outbound.queue_draft(account.id, draft.id)
    %{message: message, method: method, account: account, address: address}
  end

  defp insert_gmail_method!(account, address) do
    authorization_id = Ecto.UUID.generate()
    {:ok, access} = Crypto.encrypt("gmail-access-token", "credential:#{authorization_id}:access")

    {:ok, refresh} =
      Crypto.encrypt("gmail-refresh-token", "credential:#{authorization_id}:refresh")

    authorization =
      %OAuthAuthorization{id: authorization_id}
      |> OAuthAuthorization.changeset(%{
        account_id: account.id,
        provider: "gmail",
        provider_subject_id: "subject-#{authorization_id}",
        email_address: address,
        granted_scopes: [GmailScopes.send()],
        status: "connected",
        key_version: 1,
        access_token_ciphertext: access,
        refresh_token_ciphertext: refresh,
        token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })
      |> Repo.insert!()

    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: account.id,
      oauth_authorization_id: authorization.id,
      kind: "gmail",
      email_address: address,
      status: "connected",
      enabled: true
    })
    |> Repo.insert!()
  end

  defp insert_smtp_method!(account, address) do
    method =
      %SendMethod{}
      |> SendMethod.changeset(%{
        account_id: account.id,
        kind: "smtp",
        email_address: address,
        status: "connected",
        enabled: true
      })
      |> Repo.insert!()

    {:ok, password} = Crypto.encrypt("smtp-secret", "credential:#{method.id}:smtp_password")

    %SendCredential{}
    |> SendCredential.changeset(%{
      send_method_id: method.id,
      key_version: 1,
      password_ciphertext: password
    })
    |> Repo.insert!()

    %SmtpSettings{}
    |> SmtpSettings.changeset(%{
      send_method_id: method.id,
      host: "smtp.test",
      port: 587,
      tls_mode: "starttls",
      username: address
    })
    |> Repo.insert!()

    method
  end

  defp sha256(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end
end
