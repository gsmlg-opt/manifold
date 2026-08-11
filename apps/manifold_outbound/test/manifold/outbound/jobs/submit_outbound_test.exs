defmodule Manifold.Outbound.Jobs.SubmitOutboundTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Schema.SendMethod
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

  defp job(message_id), do: %Oban.Job{args: %{"outbound_message_id" => message_id}}

  defp queued_message_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "worker#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})

    %{message: queued, method: method, submission: submission} =
      LegacyResendFixture.queue!(mailbox.id, "inbox@#{domain.normalized_domain}", %{
        subject: "Worker",
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

  defp restore_env(key, nil), do: Application.delete_env(:manifold_outbound, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_outbound, key, value)
end
