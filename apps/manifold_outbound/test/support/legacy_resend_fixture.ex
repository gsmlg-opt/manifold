defmodule Manifold.Outbound.LegacyResendFixture do
  @moduledoc false

  alias Manifold.Connectors.Schema.SendMethod
  alias Manifold.Outbound
  alias Manifold.Outbound.Schema.ProviderSubmission
  alias Manifold.Repo

  def queue!(account_id, sender_address, draft_attrs) do
    method =
      %SendMethod{}
      |> SendMethod.changeset(%{
        account_id: account_id,
        kind: "smtp",
        email_address: sender_address,
        status: "connected",
        enabled: true
      })
      |> Repo.insert!()

    {:ok, draft} = Outbound.create_draft(account_id, draft_attrs)
    {:ok, queued} = Outbound.queue_draft(account_id, draft.id)
    current = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)
    request_sha256 = request_sha256(queued)
    now = DateTime.utc_now()

    Repo.delete!(current)
    Repo.delete!(method)

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

    %{message: queued, method: method, submission: submission}
  end

  def request_sha256(message) do
    recipients = Outbound.list_recipients(message.id)

    %{
      sender: message.sender_address,
      subject: message.subject,
      text_body: message.text_body,
      recipients:
        Enum.map(recipients, fn recipient ->
          {recipient.kind, recipient.position, recipient.canonical_address}
        end),
      in_reply_to: message.in_reply_to,
      references: message.references
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
