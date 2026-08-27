defmodule Manifold.Outbound.SubmissionTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, GmailScopes, MicrosoftScopes}

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    OAuthAuthorization,
    ReceiveMethod,
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

  setup do
    assert {:ok, _setting} =
             Connectors.put_oauth_provider_setting("gmail", %{
               "client_id" => "outbound-db-client",
               "client_secret" => "outbound-db-secret"
             })

    :ok
  end

  test "provider submission stores immutable payload fields and redacts MIME inspection" do
    sentinel = "Bcc: private-recipient@example.test\r\n\r\nprivate-body\r\n"

    changeset =
      ProviderSubmission.changeset(%ProviderSubmission{}, %{
        outbound_message_id: Ecto.UUID.generate(),
        send_method_id: Ecto.UUID.generate(),
        provider: "microsoft",
        canonical_sender_address: "sender@example.test",
        idempotency_key: Ecto.UUID.generate(),
        request_sha256: sha256(sentinel),
        request_payload: sentinel,
        render_version: 1,
        provider_rfc_message_id: "<message@manifold.local>",
        state: "pending",
        attempt_count: 0
      })

    assert changeset.valid?
    submission = Ecto.Changeset.apply_changes(changeset)

    for inspected <- [
          inspect(submission),
          inspect(%{submission: submission}),
          inspect(changeset),
          inspect(%{changeset: changeset})
        ] do
      refute inspected =~ sentinel
      refute inspected =~ "private-recipient"
    end

    assert inspect(changeset) =~ "**redacted**"
  end

  test "new method-backed snapshots reject missing payload and nonpositive render version" do
    assert %{request_payload: [_ | _]} =
             errors_on(method_submission_changeset(request_payload: nil))

    assert %{render_version: [_ | _]} =
             errors_on(method_submission_changeset(render_version: 0))
  end

  test "legacy method-backed rows remain readable and default reads omit MIME payloads" do
    %{message: message, submission: legacy} = insert_legacy_method_submission!("gmail")

    assert %ProviderSubmission{
             canonical_sender_address: canonical_sender_address,
             request_payload: nil,
             render_version: nil
           } = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)

    assert canonical_sender_address == message.canonical_sender_address

    %{message: current_message} = queued_operational_fixture("gmail")
    current = Repo.get_by!(ProviderSubmission, outbound_message_id: current_message.id)

    assert current.request_payload == nil
    assert explicit_request_payload(current.id) =~ "Stable body"
    assert explicit_request_payload(legacy.id) == nil
  end

  test "database freezes provider snapshot fields after insertion" do
    %{message: message} = queued_operational_fixture("gmail")
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)

    mutations = [
      {"outbound_message_id", Ecto.UUID.generate() |> Ecto.UUID.dump!()},
      {"send_method_id", Ecto.UUID.generate() |> Ecto.UUID.dump!()},
      {"provider", "smtp"},
      {"canonical_sender_address", "other@example.test"},
      {"idempotency_key", Ecto.UUID.generate()},
      {"request_sha256", String.duplicate("0", 64)},
      {"request_payload", "From: other@example.test\r\n\r\nChanged\r\n"},
      {"render_version", 2},
      {"provider_rfc_message_id", "<other@manifold.local>"}
    ]

    for {column, value} <- mutations do
      assert_snapshot_mutation_rejected(submission.id, column, value)
    end

    assert {1, nil} =
             ProviderSubmission
             |> where([candidate], candidate.id == ^submission.id)
             |> Repo.update_all(set: [state: "submitting"])

    assert Repo.get!(ProviderSubmission, submission.id).state == "submitting"
  end

  test "database permits one verified Gmail or SMTP legacy payload fill only" do
    for provider <- ["gmail", "smtp"] do
      payload = "From: sender@example.test\r\n\r\n#{provider} legacy body\r\n"

      %{submission: legacy} =
        insert_legacy_method_submission!(provider, request_sha256: sha256(payload))

      assert {1, nil} =
               "provider_submissions"
               |> where([candidate], field(candidate, :id) == type(^legacy.id, :binary_id))
               |> Repo.update_all(set: [request_payload: payload, render_version: 1])

      assert explicit_request_payload(legacy.id) == payload
      assert Repo.get!(ProviderSubmission, legacy.id).render_version == 1

      assert_snapshot_mutation_rejected(
        legacy.id,
        "request_payload",
        payload <> "changed"
      )
    end
  end

  test "database forbids the legacy payload-fill exception for Microsoft" do
    %{submission: legacy} = insert_legacy_method_submission!("microsoft")

    assert_snapshot_mutation_rejected(
      legacy.id,
      "request_payload",
      "From: sender@example.test\r\n\r\nMicrosoft legacy body\r\n",
      also_set_render_version: 1
    )
  end

  test "provider submission changeset is insertion-only" do
    %{message: message} = queued_operational_fixture("gmail")
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)

    changeset = ProviderSubmission.changeset(submission, %{state: "submitting"})

    refute changeset.valid?
    assert %{base: [_ | _]} = errors_on(changeset)
  end

  test "legacy Resend snapshots retain their idempotency window without method payload fields" do
    expires_at = DateTime.add(DateTime.utc_now(), 24, :hour)

    changeset =
      ProviderSubmission.changeset(%ProviderSubmission{}, %{
        outbound_message_id: Ecto.UUID.generate(),
        provider: "resend",
        canonical_sender_address: "sender@example.test",
        idempotency_key: Ecto.UUID.generate(),
        request_sha256: sha256("legacy-resend-request"),
        state: "pending",
        attempt_count: 0,
        idempotency_expires_at: expires_at
      })

    assert changeset.valid?

    assert %ProviderSubmission{
             provider: "resend",
             send_method_id: nil,
             request_payload: nil,
             render_version: nil,
             idempotency_expires_at: ^expires_at
           } = Ecto.Changeset.apply_changes(changeset)
  end

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

  test "Gmail submission checks out through the stored setting and omits OAuth client secrets" do
    %{message: message} = queued_operational_fixture("gmail")

    assert :ok =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result:
                   {:ok,
                    %Provider.Submission{
                      provider_message_id: "gmail-stored-setting",
                      metadata: %{}
                    }}
               ]
             )

    assert_receive {:provider_submit, %Provider.Request{provider: "gmail"}, config}
    assert config[:base_url] == "https://gmail.googleapis.com"
    assert config[:access_token] == "gmail-access-token"
    refute Keyword.has_key?(config, :client_id)
    refute Keyword.has_key?(config, :client_secret)

    %{message: missing_message} = queued_operational_fixture("gmail")

    Manifold.Connectors.Schema.OAuthProviderSetting
    |> Manifold.Repo.delete_all()

    assert {:error, %Provider.Error{code: "provider_not_configured"} = error} =
             Outbound.submit_message(missing_message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute inspect(error) =~ "outbound-db-secret"
    refute_receive {:provider_submit, _, _}
  end

  test "corrupt Gmail settings emit exact secret-free submission telemetry" do
    attach_submit_telemetry()
    sentinel = "outbound-corrupt-setting-secret-#{System.unique_integer([:positive])}"
    %{message: message} = queued_operational_fixture("gmail")
    setting = Repo.get_by!(Manifold.Connectors.Schema.OAuthProviderSetting, provider: "gmail")
    {:ok, corrupt_ciphertext} = Crypto.encrypt(sentinel, "wrong-provider-setting-context")

    setting
    |> Ecto.Changeset.change(client_secret_ciphertext: corrupt_ciphertext)
    |> Repo.update!()

    result =
      Outbound.submit_message(message.id,
        provider: TestProvider,
        provider_config: [test_pid: self(), result: :unused]
      )

    assert {:error, %Provider.Error{code: "provider_configuration_error"}} = result
    refute_receive {:provider_submit, _, _}

    assert_receive {:telemetry, [:manifold, :outbound, :submit, :stop], measurements,
                    %{outcome: :failed, error_code: "provider_configuration_error"} = metadata}

    assert_secret_free_telemetry(measurements, metadata, [sentinel])
    assert_secret_absent([result, measurements, metadata], sentinel)
  end

  test "recursive secret assertion detects a nested sentinel" do
    sentinel = "nested-leak-sentinel-#{System.unique_integer([:positive])}"

    assert_raise ExUnit.AssertionError, fn ->
      assert_secret_absent(%{outer: [safe: %{secret: sentinel}]}, sentinel)
    end
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

  test "stale final-attempt result cannot terminalize a newer submitting attempt" do
    %{message: message} = queued_operational_fixture("smtp")

    advance_attempt = fn preparation, _result ->
      Repo.get!(ProviderSubmission, preparation.submission_id)
      |> Ecto.Changeset.change(attempt_count: preparation.attempt_count + 1)
      |> Repo.update!()
    end

    assert {:error, %{class: :temporary, reason: :stale_submission_result}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result:
                   {:error,
                    %Provider.Error{
                      class: :transient,
                      code: "provider_unavailable",
                      message: "provider is temporarily unavailable"
                    }}
               ],
               provider_attempt_limit: 1,
               before_result_persist: advance_attempt
             )

    assert_receive {:provider_submit, _, _}
    assert Repo.get!(OutboundMessage, message.id).state == "submitting"

    persisted = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert persisted.state == "submitting"
    assert persisted.attempt_count == 2

    for event_type <- ["submission_failed", "submission_retryable"] do
      assert Repo.aggregate(
               from(event in OutboundEvent,
                 where:
                   event.outbound_message_id == ^message.id and
                     event.event_type == ^event_type
               ),
               :count
             ) == 0
    end
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

  test "Microsoft retries the persisted snapshot and accepts a bodyless 202" do
    configure_microsoft_oauth_provider!()
    %{message: message, method: method} = queued_operational_fixture("microsoft")
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    persisted_payload = explicit_request_payload(submission.id)

    message
    |> Ecto.Changeset.change(
      sender_name: "Changed Sender",
      subject: "Changed after queue",
      text_body: "Changed body",
      in_reply_to: "<changed@example.test>",
      references: ["<changed@example.test>"]
    )
    |> Repo.update!()

    transient =
      {:error,
       %Provider.Error{
         class: :transient,
         code: "rate_limited",
         message: "retry later",
         http_status: 429,
         retry_after: 5
       }}

    assert {:error, %Provider.Error{class: :transient, code: "rate_limited"}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: transient]
             )

    assert_receive {:provider_submit, first_request, first_config}
    assert first_request.provider == "microsoft"
    assert first_request.send_method_id == method.id
    assert first_request.raw_message == persisted_payload
    assert first_request.request_sha256 == submission.request_sha256
    assert Keyword.fetch!(first_config, :access_token) == "microsoft-access-token"

    assert Repo.get!(OutboundMessage, message.id).state == "queued"

    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).state ==
             "pending"

    accepted =
      {:ok,
       %Provider.Submission{
         provider_message_id: nil,
         metadata: %{"request_id" => "graph-correlation-1"}
       }}

    assert :ok =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: accepted]
             )

    assert_receive {:provider_submit, second_request, _second_config}
    assert second_request == first_request

    persisted = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert persisted.state == "accepted"
    assert persisted.provider_message_id == nil
    assert persisted.provider_metadata == %{"request_id" => "graph-correlation-1"}
  end

  test "empty provider IDs skip reconciliation without confusing correlation metadata" do
    configure_microsoft_oauth_provider!()
    %{message: message} = queued_operational_fixture("microsoft")

    accepted =
      {:ok,
       %Provider.Submission{
         provider_message_id: "",
         metadata: %{"client_request_id" => "graph-client-correlation"}
       }}

    assert :ok =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: accepted]
             )

    assert_receive {:provider_submit, _, _}
    persisted = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert persisted.provider_message_id == ""
    assert persisted.provider_metadata == %{"client_request_id" => "graph-client-correlation"}
  end

  test "bodyless Microsoft 202 stores nil provider ID and sanitized correlation metadata" do
    configure_microsoft_oauth_provider!()
    %{message: message} = queued_operational_fixture("microsoft")

    expected_payload =
      message.id
      |> then(&Repo.get_by!(ProviderSubmission, outbound_message_id: &1))
      |> then(&explicit_request_payload(&1.id))

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Base.decode64!(body) == expected_payload

      conn
      |> Plug.Conn.put_resp_header("request-id", "graph-request-202")
      |> Plug.Conn.put_resp_header("client-request-id", "graph-client-202")
      |> Plug.Conn.put_status(202)
      |> Plug.Conn.send_resp(202, "")
    end)

    assert :ok =
             Outbound.submit_message(message.id,
               provider_config: [
                 base_url: "https://graph.microsoft.test/v1.0",
                 req_options: [plug: {Req.Test, __MODULE__}]
               ]
             )

    persisted = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert persisted.provider_message_id == nil

    assert persisted.provider_metadata == %{
             "client_request_id" => "graph-client-202",
             "request_id" => "graph-request-202"
           }
  end

  test "unknown Microsoft transport loss becomes terminal uncertainty without another call" do
    configure_microsoft_oauth_provider!()
    %{message: message} = queued_operational_fixture("microsoft")

    Req.Test.expect(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %{class: :permanent, reason: :submission_uncertain}} =
             Outbound.submit_message(message.id,
               provider_config: [
                 base_url: "https://graph.microsoft.test/v1.0",
                 req_options: [plug: {Req.Test, __MODULE__}]
               ]
             )

    assert Repo.get!(OutboundMessage, message.id).state == "submission_uncertain"

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
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
  end

  test "payload integrity failure atomically terminalizes before credential checkout" do
    %{message: message, method: method} = queued_operational_fixture("microsoft")
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    request_payload = explicit_request_payload(submission.id)

    authorization = Repo.get!(OAuthAuthorization, method.oauth_authorization_id)

    authorization
    |> Ecto.Changeset.change(access_token_ciphertext: <<1, 2, 3>>)
    |> Repo.update!()

    reinsert_submission!(submission, request_sha256: String.duplicate("0", 64))

    assert {:error, %Provider.Error{class: :permanent, code: "request_integrity_failed"}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute_receive {:provider_submit, _, _}

    persisted_message = Repo.get!(OutboundMessage, message.id)
    assert persisted_message.state == "failed"
    assert persisted_message.last_error_class == "permanent"
    assert persisted_message.last_error_code == "request_integrity_failed"
    assert persisted_message.last_error_message == "outbound submission is invalid"
    assert %DateTime{} = persisted_message.failed_at

    persisted = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert persisted.state == "failed"
    assert persisted.attempt_count == 0
    assert persisted.first_attempt_at == nil
    assert persisted.last_attempt_at == nil
    assert persisted.last_error_code == "request_integrity_failed"
    assert persisted.last_error_message == "outbound submission is invalid"
    assert explicit_request_payload(persisted.id) == request_payload

    assert Repo.aggregate(
             from(event in OutboundEvent,
               where:
                 event.outbound_message_id == ^message.id and
                   event.event_type == "submission_failed"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(event in OutboundEvent,
               where:
                 event.outbound_message_id == ^message.id and
                   event.event_type == "submission_started"
             ),
             :count
           ) == 0

    assert {:error, %{class: :permanent, reason: :submission_not_retryable}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute_receive {:provider_submit, _, _}

    assert Repo.aggregate(
             from(event in OutboundEvent,
               where:
                 event.outbound_message_id == ^message.id and
                   event.event_type == "submission_failed"
             ),
             :count
           ) == 1

    %{message: sender_message, method: sender_method} =
      queued_operational_fixture("microsoft")

    sender_authorization = Repo.get!(OAuthAuthorization, sender_method.oauth_authorization_id)

    sender_authorization
    |> Ecto.Changeset.change(access_token_ciphertext: <<4, 5, 6>>)
    |> Repo.update!()

    sender_message
    |> Ecto.Changeset.change(canonical_sender_address: "other@example.test")
    |> Repo.update!()

    assert {:error, %Provider.Error{class: :permanent, code: "request_integrity_failed"}} =
             Outbound.submit_message(sender_message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    assert Repo.get_by!(ProviderSubmission, outbound_message_id: sender_message.id).attempt_count ==
             0

    assert Repo.get!(OutboundMessage, sender_message.id).state == "failed"

    assert Repo.get_by!(ProviderSubmission, outbound_message_id: sender_message.id).state ==
             "failed"

    %{message: legacy_microsoft} = insert_legacy_method_submission!("microsoft")

    assert {:error, %Provider.Error{class: :permanent, code: "request_integrity_failed"}} =
             Outbound.submit_message(legacy_microsoft.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute_receive {:provider_submit, _, _}
    assert Repo.get!(OutboundMessage, legacy_microsoft.id).state == "failed"

    assert Repo.get_by!(ProviderSubmission, outbound_message_id: legacy_microsoft.id).state ==
             "failed"
  end

  test "legacy Gmail and SMTP payloads backfill once under the submission lock" do
    for provider <- ["gmail", "smtp"] do
      %{message: message, submission: legacy} = insert_legacy_method_submission!(provider)
      assert explicit_request_payload(legacy.id) == nil
      assert legacy.render_version == nil

      accepted =
        {:ok,
         %Provider.Submission{
           provider_message_id: "legacy-#{provider}",
           metadata: %{}
         }}

      assert :ok =
               Outbound.submit_message(message.id,
                 provider: TestProvider,
                 provider_config: [test_pid: self(), result: accepted]
               )

      assert_receive {:provider_submit, request, _config}
      assert sha256(request.raw_message) == legacy.request_sha256
      assert explicit_request_payload(legacy.id) == request.raw_message
      assert Repo.get!(ProviderSubmission, legacy.id).render_version == 1
    end

    %{message: mismatch_message, submission: mismatch} =
      insert_legacy_method_submission!("smtp", request_sha256: String.duplicate("0", 64))

    assert {:error, %Provider.Error{class: :permanent, code: "request_integrity_failed"}} =
             Outbound.submit_message(mismatch_message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute_receive {:provider_submit, _, _}
    assert explicit_request_payload(mismatch.id) == nil
    assert Repo.get!(ProviderSubmission, mismatch.id).attempt_count == 0
    assert Repo.get!(ProviderSubmission, mismatch.id).state == "failed"
    assert Repo.get!(OutboundMessage, mismatch_message.id).state == "failed"
  end

  test "interrupted Microsoft submission becomes uncertain before dispatch" do
    %{message: message} = queued_operational_fixture("microsoft")
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)

    message |> Ecto.Changeset.change(state: "submitting") |> Repo.update!()

    submission
    |> Ecto.Changeset.change(state: "submitting", attempt_count: 1)
    |> Repo.update!()

    assert {:error, %{class: :permanent, reason: :submission_uncertain}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute_receive {:provider_submit, _, _}
    assert Repo.get!(OutboundMessage, message.id).state == "submission_uncertain"
    assert Repo.get!(ProviderSubmission, submission.id).state == "uncertain"
  end

  test "Microsoft send revocation marks its shared authorization and both methods" do
    configure_microsoft_oauth_provider!()

    %{message: message, method: method, account: account, address: address} =
      queued_operational_fixture("microsoft",
        scopes: [MicrosoftScopes.read(), MicrosoftScopes.send()]
      )

    receive_method = insert_microsoft_receive!(account, method.oauth_authorization_id, address)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => %{"code" => "InvalidAuthenticationToken"}})
    end)

    assert {:error, %Provider.Error{class: :permanent, code: "reconnect_required"}} =
             Outbound.submit_message(message.id,
               provider_config: [
                 base_url: "https://graph.microsoft.test/v1.0",
                 req_options: [plug: {Req.Test, __MODULE__}]
               ]
             )

    authorization = Repo.get!(OAuthAuthorization, method.oauth_authorization_id)
    assert authorization.status == "reconnect_required"

    persisted_send = Repo.get!(SendMethod, method.id)
    assert persisted_send.status == "reconnect_required"
    refute persisted_send.enabled

    persisted_receive = Repo.get!(ReceiveMethod, receive_method.id)
    assert persisted_receive.status == "reconnect_required"
    refute persisted_receive.enabled
    refute persisted_receive.sync_enabled
  end

  test "a stale Microsoft rejection retries with the rotated authorization" do
    configure_microsoft_oauth_provider!()
    %{message: message, method: method} = queued_operational_fixture("microsoft")

    Req.Test.expect(__MODULE__, fn conn ->
      authorization = Repo.get!(OAuthAuthorization, method.oauth_authorization_id)

      {:ok, replacement} =
        Crypto.encrypt("rotated-microsoft-token", "credential:#{authorization.id}:access")

      authorization
      |> OAuthAuthorization.changeset(%{
        access_token_ciphertext: replacement,
        token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })
      |> Repo.update!()

      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => %{"code" => "InvalidAuthenticationToken"}})
    end)

    config = [
      base_url: "https://graph.microsoft.test/v1.0",
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

    assert {:error, %Provider.Error{class: :transient, code: "stale_access_token"}} =
             Outbound.submit_message(message.id, provider_config: config)

    assert Repo.get!(OAuthAuthorization, method.oauth_authorization_id).status == "connected"
    assert Repo.get!(SendMethod, method.id).status == "connected"
    assert Repo.get!(OutboundMessage, message.id).state == "queued"

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Bearer rotated-microsoft-token"
             ]

      conn |> Plug.Conn.put_status(202) |> Plug.Conn.send_resp(202, "")
    end)

    assert :ok = Outbound.submit_message(message.id, provider_config: config)
    assert Repo.get!(OutboundMessage, message.id).state == "accepted_by_provider"
    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).attempt_count == 2
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

  test "Gmail, SMTP, and Microsoft submission telemetry identifies the method without leaking message data" do
    configure_microsoft_oauth_provider!()
    handler_id = "submission-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :outbound, :submit, :stop],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for kind <- ["gmail", "smtp", "microsoft"] do
      %{message: message, method: method, account: account} = queued_operational_fixture(kind)

      assert :ok =
               Outbound.submit_message(message.id,
                 provider: TestProvider,
                 provider_config: [
                   test_pid: self(),
                   authorization_code: "raw-authorization-code",
                   password: "raw-provider-password",
                   result:
                     {:ok,
                      %Provider.Submission{
                        provider_message_id: "telemetry-provider-#{kind}",
                        metadata: %{}
                      }}
                 ]
               )

      assert_receive {:provider_submit, _, _}

      assert_receive {:telemetry, [:manifold, :outbound, :submit, :stop],
                      %{duration_ms: duration_ms, attempt_count: 1} = measurements,
                      %{
                        account_id: account_id,
                        outbound_message_id: message_id,
                        submission_id: submission_id,
                        send_method_id: method_id,
                        provider: provider,
                        method_kind: method_kind,
                        outcome: :accepted
                      } = metadata}

      assert is_integer(duration_ms) and duration_ms >= 0
      assert account_id == account.id
      assert message_id == message.id
      assert is_binary(submission_id)
      assert method_id == method.id
      assert provider == kind
      assert method_kind == kind

      assert Map.keys(metadata) |> Enum.sort() ==
               [
                 :account_id,
                 :method_kind,
                 :outbound_message_id,
                 :outcome,
                 :provider,
                 :send_method_id,
                 :submission_id
               ]

      assert_secret_free_telemetry(measurements, metadata, [
        "Stable body",
        "raw-authorization-code",
        "raw-provider-password",
        "gmail-access-token",
        "smtp-secret"
      ])
    end
  end

  test "Microsoft submission outcomes keep telemetry and durable metadata content-free" do
    configure_microsoft_oauth_provider!()
    attach_submit_telemetry()
    suffix = System.unique_integer([:positive])
    subject = "telemetry-subject-sentinel-#{suffix}"
    body = "telemetry-body-sentinel-#{suffix}"
    bcc = "telemetry-bcc-sentinel-#{suffix}@example.test"
    address = "telemetry-address-sentinel-#{suffix}@example.test"
    correlation = "telemetry-correlation-sentinel-#{suffix}"

    outcomes = [
      {:accepted,
       {:ok,
        %Provider.Submission{
          provider_message_id: nil,
          metadata: %{"request_id" => correlation}
        }}, :accepted, nil, "provider_accepted"},
      {:retryable,
       {:error,
        %Provider.Error{
          class: :transient,
          code: "rate_limited",
          message: body,
          http_status: 429,
          retry_after: 5
        }}, :retryable, "rate_limited", "submission_retryable"},
      {:permanent,
       {:error,
        %Provider.Error{
          class: :permanent,
          code: subject,
          message: address,
          http_status: 403
        }}, :failed, "provider_error", "submission_failed"},
      {:uncertain,
       {:error,
        %Provider.Error{
          class: :uncertain,
          code: "acceptance_unknown",
          message: bcc
        }}, :uncertain, :submission_uncertain, "submission_uncertain"}
    ]

    observations =
      Enum.map(outcomes, fn {result_kind, provider_result, outcome, error_code, event_type} ->
        %{message: message, method: method, account: account} =
          queued_operational_fixture("microsoft",
            draft_attrs: %{
              subject: subject,
              text_body: body,
              recipients: [
                %{kind: "to", address: address},
                %{kind: "bcc", address: bcc}
              ]
            }
          )

        submit_result =
          Outbound.submit_message(message.id,
            provider: TestProvider,
            provider_config: [test_pid: self(), result: provider_result]
          )

        case {result_kind, provider_result} do
          {:accepted, _result} ->
            assert submit_result == :ok

          {kind, {:error, error}} when kind in [:retryable, :permanent] ->
            assert submit_result == {:error, error}

          {:uncertain, _result} ->
            assert {:error, %Manifold.Core.Error{reason: :submission_uncertain}} = submit_result
        end

        assert_receive {:provider_submit, _, _}

        assert_receive {:telemetry, [:manifold, :outbound, :submit, :stop],
                        %{duration_ms: duration_ms, attempt_count: 1} = measurements, metadata}

        assert is_integer(duration_ms) and duration_ms >= 0

        expected_metadata = %{
          account_id: account.id,
          outbound_message_id: message.id,
          submission_id: Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).id,
          send_method_id: method.id,
          provider: "microsoft",
          method_kind: "microsoft",
          outcome: outcome
        }

        expected_metadata =
          if error_code,
            do: Map.put(expected_metadata, :error_code, error_code),
            else: expected_metadata

        assert metadata == expected_metadata

        event =
          Repo.get_by!(OutboundEvent,
            outbound_message_id: message.id,
            event_type: event_type
          )

        submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)

        connector_event_metadata =
          ConnectorEvent
          |> where(
            [event],
            event.oauth_authorization_id == ^method.oauth_authorization_id
          )
          |> select([event], event.metadata)
          |> Repo.all()

        job_args =
          Repo.get_by!(Oban.Job,
            worker: inspect(SubmitOutbound),
            args: %{"outbound_message_id" => message.id}
          ).args

        %{
          measurements: measurements,
          telemetry: metadata,
          outbound_event: event.metadata,
          connector_events: connector_event_metadata,
          provider_metadata: submission.provider_metadata,
          job_args: job_args
        }
      end)

    assert Enum.any?(
             observations,
             &(&1.provider_metadata == %{"request_id" => correlation})
           )

    inspected = inspect(observations)

    for sentinel <- [subject, body, bcc, address] do
      refute inspected =~ sentinel
    end
  end

  test "send-method selection failure telemetry excludes draft content" do
    handler_id = "send-method-selection-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :outbound, :send_method, :select, :stop],
        fn event, measurements, metadata, pid ->
          send(pid, {:selection_telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    suffix = System.unique_integer([:positive])
    subject = "selection-subject-sentinel-#{suffix}"
    body = "selection-body-sentinel-#{suffix}"
    bcc = "selection-bcc-sentinel-#{suffix}@example.test"
    {:ok, domain} = Accounts.create_domain(%{name: "selection-#{suffix}.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "sender"})

    assert {:ok, draft} =
             Outbound.create_draft(account.id, %{
               subject: subject,
               text_body: body,
               recipients: [
                 %{kind: "to", address: "recipient@example.test"},
                 %{kind: "bcc", address: bcc}
               ]
             })

    assert {:error, %Manifold.Core.Error{reason: :send_method_required}} =
             Outbound.queue_draft(account.id, draft.id)

    assert_receive {:selection_telemetry, [:manifold, :outbound, :send_method, :select, :stop],
                    %{duration_ms: duration_ms, attempt_count: 1} = measurements,
                    %{
                      account_id: account_id,
                      outbound_message_id: outbound_message_id,
                      outcome: :error,
                      error_code: :send_method_required
                    } = metadata}

    assert is_integer(duration_ms) and duration_ms >= 0
    assert account_id == account.id
    assert outbound_message_id == draft.id

    event_metadata =
      OutboundEvent
      |> where([event], event.outbound_message_id == ^draft.id)
      |> select([event], event.metadata)
      |> Repo.all()

    inspected =
      inspect(%{measurements: measurements, telemetry: metadata, events: event_metadata})

    for sentinel <- [subject, body, bcc] do
      refute inspected =~ sentinel
    end
  end

  test "submission error telemetry carries only a normalized error code" do
    %{message: message, method: method} = queued_operational_fixture("smtp")
    handler_id = "submission-error-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :outbound, :submit, :stop],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    error = %Provider.Error{
      class: :transient,
      code: "raw_provider_password",
      message: "raw-provider-password and telemetry-test-body-secret"
    }

    assert {:error, ^error} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: {:error, error}]
             )

    assert_receive {:provider_submit, _, _}

    assert_receive {:telemetry, [:manifold, :outbound, :submit, :stop], measurements,
                    %{
                      outbound_message_id: message_id,
                      send_method_id: method_id,
                      outcome: :retryable,
                      error_code: "provider_error"
                    } = metadata}

    assert message_id == message.id
    assert method_id == method.id

    assert_secret_free_telemetry(measurements, metadata, [
      "raw-provider-password",
      "telemetry-test-body-secret"
    ])
  end

  test "submission telemetry maps arbitrary provider codes to provider_error" do
    attach_submit_telemetry()

    for {code, expected_code} <- [
          {"Stable body", "provider_error"},
          {"smtp-secret", "provider_error"},
          {String.duplicate("a7", 32), "provider_error"},
          {"transport_error", "transport_error"}
        ] do
      %{message: message} = queued_operational_fixture("smtp")

      error = %Provider.Error{
        class: :transient,
        code: code,
        message: "provider failure"
      }

      assert {:error, ^error} =
               Outbound.submit_message(message.id,
                 provider: TestProvider,
                 provider_config: [test_pid: self(), result: {:error, error}]
               )

      assert_receive {:provider_submit, _, _}

      assert_receive {:telemetry, [:manifold, :outbound, :submit, :stop], measurements,
                      %{error_code: ^expected_code} = metadata}

      assert_secret_free_telemetry(measurements, metadata, [
        "Stable body",
        "smtp-secret",
        String.duplicate("a7", 32)
      ])
    end
  end

  test "submission emits one sanitized stop event when a database failure is rescued" do
    %{message: message} = queued_operational_fixture("smtp")
    attach_submit_telemetry()

    database_error = %DBConnection.ConnectionError{
      message: "database-password-secret after provider I/O"
    }

    assert {:error, %{class: :temporary, reason: :database_unavailable}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result:
                   {:ok,
                    %Provider.Submission{
                      provider_message_id: "accepted-before-database-error",
                      metadata: %{}
                    }}
               ],
               before_result_persist: fn _preparation, _result -> raise database_error end
             )

    assert_receive {:provider_submit, _, _}

    assert_receive {:telemetry, [:manifold, :outbound, :submit, :stop], measurements,
                    %{
                      outbound_message_id: outbound_message_id,
                      outcome: :error,
                      error_code: :database_unavailable
                    } = metadata}

    assert outbound_message_id == message.id
    assert_secret_free_telemetry(measurements, metadata, ["database-password-secret"])
    refute_receive {:telemetry, [:manifold, :outbound, :submit, :stop], _, _}
    assert Repo.get!(OutboundMessage, message.id).state == "submitting"
  end

  test "submission emits one sanitized stop event before reraising an unexpected exception" do
    %{message: message} = queued_operational_fixture("smtp")
    attach_submit_telemetry()
    exception = RuntimeError.exception("raw_message unexpected-exception-secret")

    assert_raise RuntimeError, "raw_message unexpected-exception-secret", fn ->
      Outbound.submit_message(message.id,
        provider: TestProvider,
        provider_config: [
          test_pid: self(),
          result:
            {:ok,
             %Provider.Submission{
               provider_message_id: "accepted-before-unexpected-exception",
               metadata: %{}
             }}
        ],
        before_result_persist: fn _preparation, _result -> raise exception end
      )
    end

    assert_receive {:provider_submit, _, _}

    assert_receive {:telemetry, [:manifold, :outbound, :submit, :stop], measurements,
                    %{
                      outbound_message_id: outbound_message_id,
                      outcome: :error,
                      error_code: :unexpected_exception
                    } = metadata}

    assert outbound_message_id == message.id
    assert_secret_free_telemetry(measurements, metadata, ["unexpected-exception-secret"])
    refute_receive {:telemetry, [:manifold, :outbound, :submit, :stop], _, _}
    assert Repo.get!(OutboundMessage, message.id).state == "submitting"
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

  test "switching the enabled method never reroutes a queued Microsoft snapshot" do
    %{message: message, method: snapshot, account: account, address: address} =
      queued_operational_fixture("microsoft")

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert submission.send_method_id == snapshot.id

    alternate =
      %SendMethod{}
      |> SendMethod.changeset(%{
        account_id: account.id,
        kind: "smtp",
        email_address: address,
        status: "connected",
        enabled: false
      })
      |> Repo.insert!()

    assert {:ok, %SendMethod{id: alternate_id, enabled: true}} =
             Connectors.enable_send_method(account.id, alternate.id)

    assert alternate_id == alternate.id
    refute Repo.get!(SendMethod, snapshot.id).enabled

    assert {:error, %Provider.Error{class: :permanent, code: "send_method_required"}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute_receive {:provider_submit, _, _}

    persisted = Repo.get!(ProviderSubmission, submission.id)
    assert persisted.send_method_id == snapshot.id
    assert persisted.send_method_id != alternate.id
    assert persisted.state == "failed"
    assert Repo.get!(OutboundMessage, message.id).state == "failed"
  end

  test "rendered SHA tampering fails before credential decryption or provider I/O" do
    %{message: tampered_message} = queued_operational_fixture("smtp")
    tampered = Repo.get_by!(ProviderSubmission, outbound_message_id: tampered_message.id)

    Repo.get_by!(SendCredential, send_method_id: tampered.send_method_id)
    |> Ecto.Changeset.change(password_ciphertext: <<1, 2, 3>>)
    |> Repo.update!()

    reinsert_submission!(tampered, request_sha256: String.duplicate("0", 64))

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

    reinsert_submission!(tampered, request_sha256: String.duplicate("0", 64))

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

    assert_snapshot_mutation_rejected(submission.id, "provider", "smtp")
    assert_snapshot_mutation_rejected(submission.id, "send_method_id", nil)
    assert_snapshot_mutation_rejected(submission.id, "provider", "unknown")
  end

  test "Gmail API reconnect marks the current token generation and retries a stale token" do
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

    assert {:error, %Provider.Error{class: :transient, code: "stale_access_token"}} =
             Outbound.submit_message(stale_message.id,
               provider_config: [
                 base_url: "https://gmail.test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               ]
             )

    assert Repo.get!(OAuthAuthorization, stale_method.oauth_authorization_id).status ==
             "connected"

    assert Repo.get!(SendMethod, stale_method.id).status == "connected"

    assert Repo.get!(OutboundMessage, stale_message.id).state == "queued"

    assert Repo.get_by!(ProviderSubmission, outbound_message_id: stale_message.id).state ==
             "pending"

    previous_providers = Application.get_env(:manifold_connectors, :providers)

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        base_url: "https://gmail.test",
        req_options: [plug: {Req.Test, __MODULE__}]
      ]
    )

    on_exit(fn -> restore_env(:manifold_connectors, :providers, previous_providers) end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer new-access-token"]

      Req.Test.json(conn, %{"id" => "gmail-retried", "threadId" => "thread-retried"})
    end)

    assert :ok =
             SubmitOutbound.perform(%Oban.Job{
               args: %{"outbound_message_id" => stale_message.id}
             })

    assert Repo.get!(OutboundMessage, stale_message.id).state == "accepted_by_provider"

    assert Repo.get_by!(ProviderSubmission, outbound_message_id: stale_message.id).attempt_count ==
             2
  end

  test "Gmail insufficient scope marks the current authorization actionable" do
    %{message: message, method: method} = queued_operational_fixture("gmail")

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{
        "error" => %{
          "errors" => [%{"reason" => "insufficientPermissions"}]
        }
      })
    end)

    assert {:error, %Provider.Error{class: :permanent, code: "insufficient_scope"}} =
             Outbound.submit_message(message.id,
               provider_config: [
                 base_url: "https://gmail.test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               ]
             )

    authorization = Repo.get!(OAuthAuthorization, method.oauth_authorization_id)
    assert authorization.status == "reconnect_required"
    assert authorization.last_error_code == "insufficient_scope"

    persisted_method = Repo.get!(SendMethod, method.id)
    assert persisted_method.status == "reconnect_required"
    refute persisted_method.enabled

    persisted_message = Repo.get!(OutboundMessage, message.id)
    assert persisted_message.state == "failed"
    assert persisted_message.last_error_class == "permanent"
    assert persisted_message.last_error_code == "insufficient_scope"
  end

  test "Gmail reconnect lifecycle failure is retryable without resending" do
    %{message: first_message, method: method} = queued_operational_fixture("gmail")

    {:ok, second_draft} =
      Outbound.create_draft(method.account_id, %{
        subject: "Second reconnect",
        text_body: "Body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    {:ok, second_message} = Outbound.queue_draft(method.account_id, second_draft.id)

    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    result =
      Outbound.submit_message(first_message.id,
        provider_config: [
          base_url: "https://gmail.test",
          req_options: [plug: {Req.Test, __MODULE__}]
        ],
        reconnect_opts: [fail_at: :after_methods_before_event]
      )

    assert {:error, %{class: :temporary, reason: :oauth_reconnect_lifecycle_failed}} = result

    refute inspect(result) =~ "gmail-access-token"
    assert Repo.get!(OutboundMessage, first_message.id).state == "submitting"
    assert Repo.get!(OAuthAuthorization, method.oauth_authorization_id).status == "connected"
    assert Repo.get!(SendMethod, method.id).status == "connected"

    assert {:error, %{reason: :submission_uncertain}} =
             Outbound.submit_message(first_message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: :unused]
             )

    refute_receive {:provider_submit, _, _}

    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    assert {:error, %Provider.Error{class: :permanent, code: "reconnect_required"}} =
             Outbound.submit_message(second_message.id,
               provider_config: [
                 base_url: "https://gmail.test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               ]
             )

    assert Repo.get!(OAuthAuthorization, method.oauth_authorization_id).status ==
             "reconnect_required"

    assert Repo.get!(SendMethod, method.id).status == "reconnect_required"
    assert Repo.get!(OutboundMessage, second_message.id).state == "failed"
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

    address = "inbox@#{domain.normalized_domain}"

    method =
      %SendMethod{}
      |> SendMethod.changeset(%{
        account_id: mailbox.id,
        kind: "smtp",
        email_address: address,
        status: "connected",
        enabled: true
      })
      |> Repo.insert!()

    {:ok, draft} =
      Outbound.create_draft(mailbox.id, %{
        subject: "Ready",
        text_body: "Body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)
    current = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)
    Repo.delete!(current)
    Repo.delete!(method)

    now = DateTime.utc_now()
    request_sha256 = LegacyResendFixture.request_sha256(queued)

    {1, nil} =
      Repo.insert_all(ProviderSubmission, [
        %{
          id: current.id,
          outbound_message_id: queued.id,
          send_method_id: nil,
          provider: "resend",
          canonical_sender_address: queued.canonical_sender_address,
          idempotency_key: current.idempotency_key,
          request_sha256: request_sha256,
          request_payload: nil,
          render_version: nil,
          state: "pending",
          attempt_count: 0,
          provider_rfc_message_id: nil,
          idempotency_expires_at: DateTime.add(now, 24, :hour),
          provider_metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      ])

    submission = Repo.get!(ProviderSubmission, current.id)

    assert Repo.get(SendMethod, method.id) == nil

    assert {:error, %{reason: :send_method_required}} =
             Connectors.checkout_send_method(method.id, queued.sender_address)

    assert %{
             send_method_id: nil,
             provider: "resend",
             provider_rfc_message_id: nil,
             idempotency_expires_at: %DateTime{}
           } = submission

    assert submission.request_sha256 == request_sha256
    queued
  end

  defp method_submission_changeset(overrides) do
    attrs = %{
      outbound_message_id: Ecto.UUID.generate(),
      send_method_id: Ecto.UUID.generate(),
      provider: "microsoft",
      canonical_sender_address: "sender@example.test",
      idempotency_key: Ecto.UUID.generate(),
      request_payload: "From: sender@example.test\r\n\r\nBody\r\n",
      render_version: 1,
      provider_rfc_message_id: "<message@manifold.local>",
      state: "pending",
      attempt_count: 0
    }

    attrs = Map.merge(attrs, Map.new(overrides))
    attrs = Map.put(attrs, :request_sha256, sha256(attrs.request_payload || ""))
    ProviderSubmission.changeset(%ProviderSubmission{}, attrs)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp explicit_request_payload(submission_id) do
    ProviderSubmission
    |> where([submission], submission.id == ^submission_id)
    |> select([submission], submission.request_payload)
    |> Repo.one!()
  end

  defp reinsert_submission!(submission, attrs) do
    row =
      submission
      |> Map.from_struct()
      |> Map.take(ProviderSubmission.__schema__(:fields))
      |> Map.put(:request_payload, explicit_request_payload(submission.id))
      |> Map.merge(Map.new(attrs))

    Repo.delete!(submission)
    assert {1, nil} = Repo.insert_all(ProviderSubmission, [row])
    Repo.get!(ProviderSubmission, submission.id)
  end

  defp insert_legacy_method_submission!(provider, opts \\ []) do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "legacy-#{provider}-#{suffix}.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "sender", name: "Sender"})
    address = "sender@#{domain.normalized_domain}"

    method =
      case provider do
        "gmail" -> insert_gmail_method!(account, address)
        "smtp" -> insert_smtp_method!(account, address)
        "microsoft" -> insert_microsoft_method!(account, address)
      end

    {:ok, draft} =
      Outbound.create_draft(account.id, %{
        subject: "Legacy #{provider}",
        text_body: "Legacy body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    {:ok, message} = Outbound.queue_draft(account.id, draft.id)
    current = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    Repo.delete!(current)
    now = DateTime.utc_now()

    row = %{
      id: current.id,
      outbound_message_id: message.id,
      send_method_id: method.id,
      provider: provider,
      canonical_sender_address: message.canonical_sender_address,
      idempotency_key: current.idempotency_key,
      request_sha256: Keyword.get(opts, :request_sha256, current.request_sha256),
      request_payload: nil,
      render_version: nil,
      state: "pending",
      attempt_count: 0,
      provider_rfc_message_id: current.provider_rfc_message_id,
      idempotency_expires_at: nil,
      provider_metadata: %{},
      inserted_at: now,
      updated_at: now
    }

    assert {1, nil} = Repo.insert_all(ProviderSubmission, [row])

    %{
      message: message,
      method: method,
      submission: Repo.get!(ProviderSubmission, current.id)
    }
  end

  defp assert_snapshot_mutation_rejected(submission_id, column, value, opts \\ []) do
    render_version_sql =
      if Keyword.get(opts, :also_set_render_version), do: ", render_version = 1", else: ""

    assert_raise Postgrex.Error, ~r/provider submission snapshot is immutable/, fn ->
      Repo.transaction(
        fn ->
          Repo.query!(
            "UPDATE provider_submissions SET #{column} = $1#{render_version_sql} WHERE id = $2",
            [value, Ecto.UUID.dump!(submission_id)]
          )
        end,
        mode: :savepoint
      )
    end
  end

  defp queued_operational_fixture(kind, opts \\ []) do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "dispatch#{suffix}.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "sender", name: "Sender"})
    address = "sender@#{domain.normalized_domain}"

    method =
      case kind do
        "gmail" -> insert_gmail_method!(account, address)
        "smtp" -> insert_smtp_method!(account, address)
        "microsoft" -> insert_microsoft_method!(account, address, opts)
      end

    draft_attrs =
      Keyword.get(opts, :draft_attrs, %{
        subject: "Operational",
        text_body: "Stable body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    {:ok, draft} = Outbound.create_draft(account.id, draft_attrs)

    {:ok, message} = Outbound.queue_draft(account.id, draft.id)
    %{message: message, method: method, account: account, address: address}
  end

  defp configure_microsoft_oauth_provider! do
    assert {:ok, _setting} =
             Connectors.put_oauth_provider_setting("microsoft", %{
               "client_id" => "outbound-microsoft-db-client",
               "client_secret" => "outbound-microsoft-db-secret"
             })
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

  defp insert_microsoft_method!(account, address, opts \\ []) do
    authorization_id = Ecto.UUID.generate()

    {:ok, access} =
      Crypto.encrypt("microsoft-access-token", "credential:#{authorization_id}:access")

    {:ok, refresh} =
      Crypto.encrypt("microsoft-refresh-token", "credential:#{authorization_id}:refresh")

    authorization =
      %OAuthAuthorization{id: authorization_id}
      |> OAuthAuthorization.changeset(%{
        account_id: account.id,
        provider: "microsoft",
        provider_subject_id: "subject-#{authorization_id}",
        email_address: address,
        granted_scopes: Keyword.get(opts, :scopes, [MicrosoftScopes.send()]),
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
      kind: "microsoft",
      email_address: address,
      status: "connected",
      enabled: true
    })
    |> Repo.insert!()
  end

  defp insert_microsoft_receive!(account, authorization_id, address) do
    %ReceiveMethod{}
    |> ReceiveMethod.changeset(%{
      account_id: account.id,
      oauth_authorization_id: authorization_id,
      kind: "microsoft",
      provider_account_id: "receive-#{authorization_id}",
      email_address: address,
      status: "connected",
      enabled: true,
      sync_enabled: true,
      granted_scopes: [MicrosoftScopes.read()]
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

  defp assert_secret_free_telemetry(measurements, metadata, secret_values) do
    assert Map.keys(measurements) |> Enum.sort() == [:attempt_count, :duration_ms]

    forbidden_fragments =
      ~w(token password authorization_code raw_message) ++
        Enum.map(secret_values, &String.downcase/1)

    telemetry_terms(measurements)
    |> Enum.concat(telemetry_terms(metadata))
    |> Enum.each(fn term ->
      downcased = term |> to_string() |> String.downcase()

      refute Enum.any?(forbidden_fragments, &String.contains?(downcased, &1)),
             "unsafe telemetry term: #{inspect(term)}"
    end)
  end

  defp telemetry_terms(map) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.flat_map(fn {key, value} -> [key | telemetry_terms(value)] end)
  end

  defp telemetry_terms(list) when is_list(list), do: Enum.flat_map(list, &telemetry_terms/1)

  defp telemetry_terms(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> telemetry_terms()

  defp telemetry_terms(value), do: [value]

  defp assert_secret_absent(term, sentinel) do
    term
    |> telemetry_terms()
    |> Enum.each(fn
      value when is_binary(value) -> assert :binary.match(value, sentinel) == :nomatch
      value -> refute inspect(value) =~ sentinel
    end)

    refute inspect(term) =~ sentinel
  end

  defp attach_submit_telemetry do
    handler_id = "submission-stop-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :outbound, :submit, :stop],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
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
