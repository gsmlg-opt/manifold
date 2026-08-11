defmodule Manifold.Outbound.SubmissionTest do
  use Manifold.DataCase, async: false

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
  alias Manifold.Outbound.Jobs.SubmitOutbound
  alias Manifold.Outbound.LegacyResendFixture
  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Schema.{OutboundEvent, OutboundMessage, ProviderSubmission}
  alias Manifold.Repo

  defmodule TestProvider do
    @behaviour Manifold.Outbound.Provider

    @impl true
    def submit(config, request) do
      send(Keyword.fetch!(config, :test_pid), {:provider_submit, request, config})

      if Keyword.get(config, :gate) do
        receive do
          :release_provider -> :ok
        end
      end

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

  defmodule CheckoutFailureGmail do
    @behaviour Manifold.Connectors.Provider

    def exchange_code(_, _, _, _, _), do: raise("not used")
    def identity(_, _, _), do: raise("not used")
    def initial_cursors(_, _, _), do: raise("not used")

    def refresh_token(_, _, opts) do
      send(Keyword.fetch!(opts, :test_pid), :gmail_refresh_attempted)
      {:error, Keyword.fetch!(opts, :refresh_error)}
    end

    def sync_page(_, _, _, _), do: raise("not used")
    def fetch_raw(_, _, _, _), do: raise("not used")
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

  test "interrupted non-idempotent submission becomes uncertain without a second provider call" do
    %{message: message} = queued_operational_fixture("smtp")
    success = {:ok, %Provider.Submission{provider_message_id: "maybe-accepted", metadata: %{}}}

    assert {:error, %{reason: :after_provider_accept_before_commit}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: success],
               fail_at: :after_provider_accept_before_commit
             )

    assert_receive {:provider_submit, _, _}
    assert Repo.get!(OutboundMessage, message.id).state == "submitting"

    assert :ok =
             SubmitOutbound.perform(%Oban.Job{
               args: %{"outbound_message_id" => message.id}
             })

    refute_receive {:provider_submit, _, _}
    assert Repo.get!(OutboundMessage, message.id).state == "submission_uncertain"
    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).state == "uncertain"
  end

  test "concurrent Gmail and SMTP submissions make exactly one provider call" do
    for kind <- ["gmail", "smtp"] do
      %{message: message} = queued_operational_fixture(kind)
      test_pid = self()

      submit = fn ->
        Outbound.submit_message(message.id,
          provider: TestProvider,
          provider_config: [
            test_pid: test_pid,
            gate: true,
            result: {:ok, %Provider.Submission{provider_message_id: "winner", metadata: %{}}}
          ]
        )
      end

      first = sandbox_task(submit)
      assert_receive {:provider_submit, _, first_config}
      first_pid = Keyword.fetch!(first_config, :test_pid)

      second = sandbox_task(submit)
      assert {:error, %{reason: :submission_uncertain}} = Task.await(second)
      refute_receive {:provider_submit, _, _}

      send(first.pid, :release_provider)
      assert {:error, %{reason: :submission_uncertain}} = Task.await(first)
      assert first_pid == self()
      assert Repo.get!(OutboundMessage, message.id).state == "submission_uncertain"
    end
  end

  test "stale provider results cannot overwrite a terminal or newer attempt" do
    %{message: accepted_message} = queued_operational_fixture("smtp")

    mark_accepted = fn preparation, _result ->
      Repo.get!(OutboundMessage, preparation.message_id)
      |> Ecto.Changeset.change(state: "accepted_by_provider", accepted_at: DateTime.utc_now())
      |> Repo.update!()

      Repo.get!(ProviderSubmission, preparation.submission_id)
      |> Ecto.Changeset.change(state: "accepted", provider_message_id: "winner")
      |> Repo.update!()
    end

    transient =
      {:error, %Provider.Error{class: :transient, code: "later", message: "later"}}

    assert :ok =
             Outbound.submit_message(accepted_message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: transient],
               before_result_persist: mark_accepted
             )

    assert Repo.get!(OutboundMessage, accepted_message.id).state == "accepted_by_provider"

    assert Repo.get_by!(ProviderSubmission, outbound_message_id: accepted_message.id).provider_message_id ==
             "winner"

    %{message: newer_message} = queued_message_fixture() |> then(&%{message: &1})

    bump_attempt = fn preparation, _result ->
      Repo.get!(ProviderSubmission, preparation.submission_id)
      |> Ecto.Changeset.change(attempt_count: preparation.attempt_count + 1)
      |> Repo.update!()
    end

    assert {:error, %{class: :temporary, reason: :stale_submission_result}} =
             Outbound.submit_message(newer_message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result: {:ok, %Provider.Submission{provider_message_id: "stale", metadata: %{}}}
               ],
               before_result_persist: bump_attempt
             )

    refute Repo.get_by!(ProviderSubmission, outbound_message_id: newer_message.id).provider_message_id
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

  test "rendered SHA tampering fails before credential decryption or provider I/O" do
    %{message: tampered_message} = queued_operational_fixture("smtp")
    tampered = Repo.get_by!(ProviderSubmission, outbound_message_id: tampered_message.id)

    Repo.get_by!(SendCredential, send_method_id: tampered.send_method_id)
    |> Ecto.Changeset.change(password_ciphertext: <<1, 2, 3>>)
    |> Repo.update!()

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

  test "checkout provider errors are normalized and SHA failure precedes Gmail refresh" do
    previous_adapters = Application.get_env(:manifold_connectors, :adapters)
    Application.put_env(:manifold_connectors, :adapters, gmail: CheckoutFailureGmail)
    on_exit(fn -> restore_env(:manifold_connectors, :adapters, previous_adapters) end)

    for {connector_class, expected_class} <- [
          {:temporary, :transient},
          {:permanent, :permanent},
          {:reconnect, :permanent},
          {:uncertain, :uncertain}
        ] do
      %{message: message, method: method} = queued_operational_fixture("gmail")
      expire_authorization!(method.oauth_authorization_id)

      error = %Manifold.Connectors.Provider.Error{
        class: connector_class,
        code: :checkout_failed,
        message: "sanitized checkout failure"
      }

      result =
        Outbound.submit_message(message.id,
          checkout_opts: [provider_opts: [test_pid: self(), refresh_error: error]],
          provider: TestProvider,
          provider_config: [test_pid: self(), result: :unused]
        )

      if expected_class == :uncertain do
        assert {:error, %{class: :permanent, reason: :submission_uncertain}} = result
        assert Repo.get!(OutboundMessage, message.id).last_error_class == "uncertain"
      else
        assert {:error, %Provider.Error{class: ^expected_class, code: "checkout_failed"}} = result
      end

      assert_receive :gmail_refresh_attempted
      refute_receive {:provider_submit, _, _}
    end

    %{message: tampered_message, method: tampered_method} = queued_operational_fixture("gmail")
    expire_authorization!(tampered_method.oauth_authorization_id)
    tampered = Repo.get_by!(ProviderSubmission, outbound_message_id: tampered_message.id)
    tampered |> Ecto.Changeset.change(request_sha256: String.duplicate("0", 64)) |> Repo.update!()

    assert {:error, %Provider.Error{code: "request_integrity_failed"}} =
             Outbound.submit_message(tampered_message.id,
               checkout_opts: [
                 provider_opts: [
                   test_pid: self(),
                   refresh_error: %Manifold.Connectors.Provider.Error{
                     class: :temporary,
                     code: :must_not_refresh,
                     message: "must not refresh"
                   }
                 ]
               ],
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute_receive :gmail_refresh_attempted
  end

  test "database rejects invalid provider and method snapshot combinations" do
    %{message: message} = queued_operational_fixture("gmail")
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)

    assert_raise Ecto.ConstraintError, fn ->
      submission |> Ecto.Changeset.change(provider: "smtp") |> Repo.update!()
    end

    assert_raise Ecto.ConstraintError, fn ->
      submission |> Ecto.Changeset.change(send_method_id: nil) |> Repo.update!()
    end

    assert_raise Ecto.ConstraintError, fn ->
      submission |> Ecto.Changeset.change(provider: "unknown") |> Repo.update!()
    end
  end

  test "Gmail API reconnect marks the current token generation but ignores a stale token" do
    %{message: current_message, method: current_method} = queued_operational_fixture("gmail")

    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    assert {:error, %Provider.Error{class: :permanent, code: "reconnect_required"}} =
             Outbound.submit_message(current_message.id,
               provider_config: [
                 base_url: "https://gmail.test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               ]
             )

    assert Repo.get!(OAuthAuthorization, current_method.oauth_authorization_id).status ==
             "reconnect_required"

    assert Repo.get!(SendMethod, current_method.id).status == "reconnect_required"

    %{message: stale_message, method: stale_method} = queued_operational_fixture("gmail")

    Req.Test.expect(__MODULE__, fn conn ->
      authorization = Repo.get!(OAuthAuthorization, stale_method.oauth_authorization_id)

      {:ok, replacement} =
        Crypto.encrypt("new-access-token", "credential:#{authorization.id}:access")

      authorization
      |> OAuthAuthorization.changeset(%{
        access_token_ciphertext: replacement,
        token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })
      |> Repo.update!()

      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    assert {:error, %Provider.Error{code: "reconnect_required"}} =
             Outbound.submit_message(stale_message.id,
               provider_config: [
                 base_url: "https://gmail.test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               ]
             )

    assert Repo.get!(OAuthAuthorization, stale_method.oauth_authorization_id).status ==
             "connected"

    assert Repo.get!(SendMethod, stale_method.id).status == "connected"
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

  defp expire_authorization!(authorization_id) do
    Repo.get!(OAuthAuthorization, authorization_id)
    |> OAuthAuthorization.changeset(%{
      token_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
    |> Repo.update!()
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp sandbox_task(fun) do
    parent = self()

    task =
      Task.async(fn ->
        receive do
          :start -> fun.()
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, task.pid)
    send(task.pid, :start)
    task
  end
end
