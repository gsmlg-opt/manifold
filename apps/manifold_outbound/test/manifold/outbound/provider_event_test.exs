defmodule Manifold.Outbound.ProviderEventTest do
  use Manifold.DataCase, async: true

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Schema.SendMethod
  alias Manifold.Outbound
  alias Manifold.Outbound.LegacyResendFixture
  alias Manifold.Outbound.Provider

  alias Manifold.Outbound.Schema.{
    OutboundRecipient,
    ProviderEvent
  }

  alias Manifold.Repo

  defmodule TestProvider do
    @behaviour Manifold.Outbound.Provider

    @impl true
    def submit(config, _envelope) do
      {:ok,
       %Provider.Submission{
         provider_message_id: Keyword.fetch!(config, :provider_message_id),
         metadata: %{}
       }}
    end
  end

  test "applies divergent recipient outcomes and deduplicates event replay" do
    message = accepted_message_fixture("provider-divergent")
    [first, second] = recipients(message.id)
    occurred_at = ~U[2026-07-29 06:00:00Z]

    delivered =
      event("event-delivered", "provider-divergent", "delivered", [first.address], occurred_at)

    bounced =
      event("event-bounced", "provider-divergent", "bounced", [second.address], occurred_at)

    assert {:ok, :processed} = Outbound.record_provider_event("resend", delivered)
    assert {:ok, :processed} = Outbound.record_provider_event("resend", bounced)
    assert {:ok, :duplicate} = Outbound.record_provider_event("resend", delivered)

    assert Repo.get!(OutboundRecipient, first.id).delivery_state == "delivered"
    assert Repo.get!(OutboundRecipient, second.id).delivery_state == "bounced"
    assert Repo.aggregate(ProviderEvent, :count) == 2
  end

  test "stores but does not apply older or lower-precedence events" do
    message = accepted_message_fixture("provider-order")
    [first | _rest] = recipients(message.id)
    newer = ~U[2026-07-29 06:00:00Z]
    older = ~U[2026-07-29 05:00:00Z]

    assert {:ok, :processed} =
             Outbound.record_provider_event(
               "resend",
               event("event-bounce", "provider-order", "bounced", [first.address], newer)
             )

    assert {:ok, :processed} =
             Outbound.record_provider_event(
               "resend",
               event("event-delivery", "provider-order", "delivered", [first.address], older)
             )

    recipient = Repo.get!(OutboundRecipient, first.id)
    assert recipient.delivery_state == "bounced"
    assert DateTime.compare(recipient.last_event_at, newer) == :eq
    assert Repo.aggregate(ProviderEvent, :count) == 2
  end

  test "unmatched event is reconciled when provider acceptance commits" do
    message = queued_message_fixture()
    [first | _rest] = recipients(message.id)

    early =
      event(
        "event-early",
        "provider-early",
        "delivered",
        [first.address],
        ~U[2026-07-29 06:00:00Z]
      )

    assert {:ok, :unmatched} = Outbound.record_provider_event("resend", early)

    assert Repo.get_by!(ProviderEvent, provider_event_id: "event-early").processing_state ==
             "unmatched"

    assert :ok =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [provider_message_id: "provider-early"]
             )

    assert Repo.get!(OutboundRecipient, first.id).delivery_state == "delivered"

    assert Repo.get_by!(ProviderEvent, provider_event_id: "event-early").processing_state ==
             "processed"
  end

  test "failure between event insertion and recipient update rolls back both" do
    message = accepted_message_fixture("provider-rollback")
    [first | _rest] = recipients(message.id)

    assert {:error, %{reason: :after_event_before_recipient_update}} =
             Outbound.record_provider_event(
               "resend",
               event(
                 "event-rollback",
                 "provider-rollback",
                 "delivered",
                 [first.address],
                 ~U[2026-07-29 06:00:00Z]
               ),
               fail_at: :after_event_before_recipient_update
             )

    refute Repo.get_by(ProviderEvent, provider_event_id: "event-rollback")
    assert Repo.get!(OutboundRecipient, first.id).delivery_state == "pending"
  end

  defp event(id, provider_message_id, state, addresses, occurred_at) do
    %Provider.Event{
      provider_event_id: id,
      provider_message_id: provider_message_id,
      event_type: "email.#{state}",
      normalized_state: state,
      recipient_addresses: addresses,
      occurred_at: occurred_at,
      metadata: %{}
    }
  end

  defp accepted_message_fixture(provider_message_id) do
    message = queued_message_fixture()

    assert :ok =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [provider_message_id: provider_message_id]
             )

    message
  end

  defp queued_message_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "event#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})

    %{message: queued, method: method, submission: submission} =
      LegacyResendFixture.queue!(mailbox.id, "inbox@#{domain.normalized_domain}", %{
        subject: "Events",
        text_body: "Body",
        recipients: [
          %{kind: "to", address: "first@example.net"},
          %{kind: "to", address: "second@example.net"}
        ]
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

  defp recipients(message_id) do
    OutboundRecipient
    |> where([recipient], recipient.outbound_message_id == ^message_id)
    |> order_by([recipient], asc: recipient.position)
    |> Repo.all()
  end
end
