defmodule Manifold.Outbound.Jobs.SubmitOutboundTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, MicrosoftScopes}
  alias Manifold.Connectors.Schema.{OAuthAuthorization, SendMethod}
  alias Manifold.Outbound
  alias Manifold.Outbound.Jobs.SubmitOutbound
  alias Manifold.Outbound.LegacyResendFixture
  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Schema.OutboundMessage
  alias Manifold.Outbound.Schema.{OutboundEvent, ProviderSubmission}
  alias Manifold.Repo

  defmodule ConfiguredProvider do
    @behaviour Manifold.Outbound.Provider

    @impl true
    def submit(config, _envelope), do: Keyword.fetch!(config, :result)
  end

  setup do
    old_adapter = Application.get_env(:manifold_outbound, :provider_adapter)
    old_config = Application.get_env(:manifold_outbound, :provider_config)

    Application.put_env(:manifold_outbound, :provider_adapter, ConfiguredProvider)
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})

    on_exit(fn ->
      restore_env(:provider_adapter, old_adapter)
      restore_env(:provider_config, old_config)
    end)
  end

  test "completes after managed provider acceptance" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result: {:ok, %Provider.Submission{provider_message_id: "worker-ok", metadata: %{}}}
    )

    assert :ok = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "accepted_by_provider"
  end

  test "returns transient errors to Oban for retry" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result:
        {:error,
         %Provider.Error{
           class: :transient,
           code: "http_503",
           message: "later",
           http_status: 503
         }}
    )

    assert {:error, "http_503"} = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "queued"
  end

  test "snoozes until a provider rate limit expires" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result:
        {:error,
         %Provider.Error{
           class: :transient,
           code: "http_429",
           message: "slow down",
           http_status: 429,
           retry_after: 75
         }}
    )

    assert {:snooze, 75} = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "queued"
  end

  test "completes terminal failures after persisting failed state" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result:
        {:error,
         %Provider.Error{
           class: :permanent,
           code: "validation_error",
           message: "bad sender",
           http_status: 422
         }}
    )

    assert :ok = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "failed"
  end

  test "completes an uncertain submission and repeated execution never resends" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result:
        {:error,
         %Provider.Error{
           class: :uncertain,
           code: "acceptance_unknown",
           message: "provider may have accepted"
         }}
    )

    assert :ok = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "submission_uncertain"
    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).state == "uncertain"

    assert :ok = SubmitOutbound.perform(job(message.id))

    assert Repo.aggregate(
             from(event in OutboundEvent,
               where:
                 event.outbound_message_id == ^message.id and
                   event.event_type == "submission_uncertain"
             ),
             :count
           ) == 1
  end

  test "Microsoft 5xx completes as uncertainty and leaves no retryable job" do
    configure_microsoft_req_test!()
    message = microsoft_message_fixture()

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => %{"code" => "ServiceUnavailable"}})
    end)

    result = Oban.drain_queue(queue: :outbound)
    assert result.success == 1

    persisted = Repo.get!(OutboundMessage, message.id)
    assert persisted.state == "submission_uncertain"

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

    assert Repo.aggregate(active_submit_jobs(message.id), :count) == 0

    assert :ok = SubmitOutbound.perform(job(message.id))
    assert Repo.aggregate(active_submit_jobs(message.id), :count) == 0
  end

  test "Microsoft 429 snoozes without changing its persisted payload" do
    configure_microsoft_req_test!()
    message = microsoft_message_fixture()
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    payload = explicit_request_payload(submission.id)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "75")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"code" => "TooManyRequests"}})
    end)

    assert {:snooze, 75} = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "queued"
    assert Repo.get!(ProviderSubmission, submission.id).state == "pending"
    assert explicit_request_payload(submission.id) == payload
  end

  defp job(message_id), do: %Oban.Job{args: %{"outbound_message_id" => message_id}}

  defp queued_message_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "worker#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})
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
        subject: "Worker",
        text_body: "Body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)
    current = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)
    Repo.delete!(current)
    Repo.delete!(method)
    now = DateTime.utc_now()

    assert {1, nil} =
             Repo.insert_all(ProviderSubmission, [
               %{
                 id: current.id,
                 outbound_message_id: queued.id,
                 send_method_id: nil,
                 provider: "resend",
                 canonical_sender_address: queued.canonical_sender_address,
                 idempotency_key: current.idempotency_key,
                 request_sha256: LegacyResendFixture.request_sha256(queued),
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

    assert submission.request_sha256 == LegacyResendFixture.request_sha256(queued)
    queued
  end

  defp microsoft_message_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "worker-microsoft#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "sender"})
    address = "sender@#{domain.normalized_domain}"
    authorization_id = Ecto.UUID.generate()

    {:ok, access} =
      Crypto.encrypt("microsoft-worker-token", "credential:#{authorization_id}:access")

    {:ok, refresh} =
      Crypto.encrypt("microsoft-worker-refresh", "credential:#{authorization_id}:refresh")

    authorization =
      %OAuthAuthorization{id: authorization_id}
      |> OAuthAuthorization.changeset(%{
        account_id: mailbox.id,
        provider: "microsoft",
        provider_subject_id: "worker-subject-#{suffix}",
        email_address: address,
        granted_scopes: [MicrosoftScopes.send()],
        status: "connected",
        key_version: 1,
        access_token_ciphertext: access,
        refresh_token_ciphertext: refresh,
        token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })
      |> Repo.insert!()

    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: mailbox.id,
      oauth_authorization_id: authorization.id,
      kind: "microsoft",
      email_address: address,
      status: "connected",
      enabled: true
    })
    |> Repo.insert!()

    {:ok, draft} =
      Outbound.create_draft(mailbox.id, %{
        subject: "Worker Microsoft",
        text_body: "Persisted worker body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)
    queued
  end

  defp configure_microsoft_req_test! do
    previous = Application.get_env(:manifold_connectors, :providers, [])

    configured =
      Keyword.put(previous, :microsoft,
        base_url: "https://graph.microsoft.test/v1.0",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    Application.put_env(:manifold_connectors, :providers, configured)
    on_exit(fn -> Application.put_env(:manifold_connectors, :providers, previous) end)
  end

  defp explicit_request_payload(submission_id) do
    ProviderSubmission
    |> where([submission], submission.id == ^submission_id)
    |> select([submission], submission.request_payload)
    |> Repo.one!()
  end

  defp active_submit_jobs(message_id) do
    from(job in Oban.Job,
      where:
        job.worker == ^inspect(SubmitOutbound) and
          job.state in ~w(available scheduled retryable) and
          fragment("?->>'outbound_message_id' = ?", job.args, ^message_id)
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_outbound, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_outbound, key, value)
end
