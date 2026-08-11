defmodule Manifold.OutboundTest do
  use Manifold.DataCase, async: true

  alias Manifold.Accounts
  alias Manifold.Connectors.Schema.SendMethod
  alias Manifold.Outbound
  alias Manifold.Outbound.Jobs.SubmitOutbound
  alias Manifold.Outbound.Provider.Envelope
  alias Manifold.Outbound.RfcMessage

  alias Manifold.Outbound.Schema.{
    OutboundEvent,
    OutboundMessage,
    OutboundRecipient,
    ProviderSubmission
  }

  alias Manifold.Repo

  test "creates and updates an editable draft with frozen sender and recipients" do
    %{mailbox: mailbox, address: sender_address} = mailbox_fixture()

    assert {:ok, draft} =
             Outbound.create_draft(mailbox.id, %{
               subject: "Draft subject",
               text_body: "Draft body",
               recipients: [
                 %{kind: "to", address: "First@Example.net", name: "First"},
                 %{kind: "cc", address: "copy@example.net"}
               ]
             })

    assert draft.state == "draft"
    assert draft.sender_address == sender_address
    assert draft.subject == "Draft subject"

    assert Repo.get_by!(OutboundEvent, outbound_message_id: draft.id).event_type ==
             "draft_created"

    assert [
             %{kind: "to", address: "First@Example.net", canonical_address: "first@example.net"},
             %{kind: "cc", address: "copy@example.net", canonical_address: "copy@example.net"}
           ] = Outbound.list_recipients(draft.id)

    assert {:ok, updated} =
             Outbound.update_draft(
               mailbox.id,
               draft.id,
               %{
                 subject: "Updated",
                 text_body: "Changed",
                 recipients: [%{kind: "to", address: "replacement@example.net"}]
               },
               expected_revision: draft.lock_version
             )

    assert updated.subject == "Updated"
    assert updated.text_body == "Changed"
    assert [%{address: "replacement@example.net"}] = Outbound.list_recipients(draft.id)

    assert {:error, %{reason: :stale_draft}} =
             Outbound.update_draft(
               mailbox.id,
               draft.id,
               %{subject: "Stale"},
               expected_revision: draft.lock_version
             )
  end

  test "queueing freezes the draft and inserts exactly one Oban job transactionally" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    method = send_method_fixture(mailbox.id, address, "gmail")
    draft = draft_fixture(mailbox.id, include_bcc: true)

    assert {:ok, queued} =
             Outbound.queue_draft(mailbox.id, draft.id, expected_revision: draft.lock_version)

    assert queued.state == "queued"
    assert %DateTime{} = queued.queued_at

    assert %Oban.Job{
             worker: worker,
             args: %{"outbound_message_id" => outbound_message_id}
           } = Repo.one!(Oban.Job)

    assert worker == inspect(SubmitOutbound)
    assert outbound_message_id == draft.id

    assert %ProviderSubmission{
             outbound_message_id: ^outbound_message_id,
             send_method_id: send_method_id,
             provider: "gmail",
             state: "pending",
             idempotency_key: idempotency_key,
             request_sha256: request_sha256,
             provider_rfc_message_id: provider_rfc_message_id,
             idempotency_expires_at: nil
           } = Repo.one!(ProviderSubmission)

    assert send_method_id == method.id
    assert provider_rfc_message_id == "<#{queued.id}@manifold.local>"
    assert byte_size(idempotency_key) > 0

    expected_raw = expected_raw(queued, "gmail", idempotency_key)
    assert expected_raw =~ "Bcc: hidden@example.net\r\n"
    assert request_sha256 == sha256(expected_raw)
    assert Repo.get_by!(OutboundEvent, outbound_message_id: draft.id, event_type: "queued")

    assert {:ok, repeated} = Outbound.queue_draft(mailbox.id, draft.id)
    assert repeated.id == draft.id
    assert Repo.aggregate(Oban.Job, :count) == 1
    assert Repo.aggregate(ProviderSubmission, :count) == 1

    assert {:error, %{reason: :message_not_editable}} =
             Outbound.update_draft(mailbox.id, draft.id, %{subject: "Too late"})
  end

  test "queue transaction failure rolls back state and job insertion" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")
    draft = draft_fixture(mailbox.id)

    assert {:error, %{reason: :after_queue_before_job}} =
             Outbound.queue_draft(mailbox.id, draft.id, fail_at: :after_queue_before_job)

    assert Repo.get!(OutboundMessage, draft.id).state == "draft"
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(ProviderSubmission, :count) == 0
  end

  test "queueing without an operational send method leaves the draft unchanged" do
    %{mailbox: mailbox} = mailbox_fixture()
    draft = draft_fixture(mailbox.id)

    assert {:error, %{class: :permanent, reason: :send_method_required}} =
             Outbound.queue_draft(mailbox.id, draft.id)

    assert Repo.get!(OutboundMessage, draft.id).state == "draft"
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(ProviderSubmission, :count) == 0
  end

  test "queueing snapshots SMTP bytes without a Bcc header" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    method = send_method_fixture(mailbox.id, address, "smtp")
    draft = draft_fixture(mailbox.id, include_bcc: true)

    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)
    expected_raw = expected_raw(queued, "smtp", submission.idempotency_key)

    assert submission.send_method_id == method.id
    assert submission.provider == "smtp"
    assert submission.provider_rfc_message_id == "<#{queued.id}@manifold.local>"
    assert submission.idempotency_expires_at == nil
    refute expected_raw =~ "Bcc:"
    assert submission.request_sha256 == sha256(expected_raw)
  end

  test "queueing rejects a draft sender that differs from the selected method" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")

    draft =
      mailbox.id
      |> draft_fixture()
      |> Ecto.Changeset.change(
        sender_address: "other@example.test",
        canonical_sender_address: "other@example.test"
      )
      |> Repo.update!()

    assert {:error, %{class: :permanent, reason: :sender_address_mismatch}} =
             Outbound.queue_draft(mailbox.id, draft.id)

    assert Repo.get!(OutboundMessage, draft.id).state == "draft"
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(ProviderSubmission, :count) == 0
  end

  test "an already queued message keeps its method snapshot after the enabled method changes" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    gmail = send_method_fixture(mailbox.id, address, "gmail")
    draft = draft_fixture(mailbox.id)

    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)
    original = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)

    gmail |> SendMethod.changeset(%{enabled: false}) |> Repo.update!()
    smtp = send_method_fixture(mailbox.id, address, "smtp")

    assert {:ok, repeated} = Outbound.queue_draft(mailbox.id, draft.id)
    assert repeated.id == queued.id

    persisted = Repo.get!(ProviderSubmission, original.id)
    assert persisted.send_method_id == gmail.id
    refute persisted.send_method_id == smtp.id
    assert persisted.provider == "gmail"
    assert persisted.request_sha256 == original.request_sha256
    assert persisted.provider_rfc_message_id == original.provider_rfc_message_id
    assert Repo.aggregate(ProviderSubmission, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "rejects invalid or duplicate recipient addresses" do
    %{mailbox: mailbox} = mailbox_fixture()

    assert {:error, %{reason: :invalid_recipient}} =
             Outbound.create_draft(mailbox.id, %{
               subject: "Invalid",
               text_body: "Body",
               recipients: [%{kind: "to", address: "not-an-address"}]
             })

    assert {:error, %{reason: :duplicate_recipient}} =
             Outbound.create_draft(mailbox.id, %{
               subject: "Duplicate",
               text_body: "Body",
               recipients: [
                 %{kind: "to", address: "person@example.net"},
                 %{kind: "cc", address: "PERSON@example.net"}
               ]
             })

    assert Repo.aggregate(OutboundMessage, :count) == 0
    assert Repo.aggregate(OutboundRecipient, :count) == 0
  end

  test "inactive mailbox cannot create an outbound draft" do
    %{mailbox: mailbox} = mailbox_fixture()

    mailbox
    |> Ecto.Changeset.change(active: false)
    |> Repo.update!()

    assert {:error, %{reason: :sender_not_active}} =
             Outbound.create_draft(mailbox.id, %{
               subject: "No send",
               text_body: "Body",
               recipients: [%{kind: "to", address: "person@example.net"}]
             })
  end

  test "draft identifiers remain mailbox scoped" do
    %{mailbox: first_mailbox} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()
    draft = draft_fixture(first_mailbox.id)

    assert {:error, %{reason: :draft_not_found}} =
             Outbound.update_draft(other_mailbox.id, draft.id, %{subject: "Cross mailbox"})

    assert {:error, %{reason: :draft_not_found}} =
             Outbound.queue_draft(other_mailbox.id, draft.id)
  end

  test "lists and deletes drafts within one mailbox" do
    %{mailbox: mailbox} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()
    first = draft_fixture(mailbox.id)
    second = draft_fixture(mailbox.id)
    _other = draft_fixture(other_mailbox.id)

    assert [listed_second, listed_first] = Outbound.list_drafts(mailbox.id)
    assert listed_second.id == second.id
    assert listed_first.id == first.id

    assert {:ok, deleted} = Outbound.delete_draft(mailbox.id, first.id)
    assert deleted.id == first.id
    assert [remaining] = Outbound.list_drafts(mailbox.id)
    assert remaining.id == second.id

    assert {:error, %{reason: :draft_not_found}} =
             Outbound.delete_draft(other_mailbox.id, second.id)
  end

  test "sent list excludes drafts and remains mailbox scoped" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    %{mailbox: other_mailbox, address: other_address} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")
    send_method_fixture(other_mailbox.id, other_address, "smtp")
    draft = draft_fixture(mailbox.id)
    queued = draft_fixture(mailbox.id)
    other_queued = draft_fixture(other_mailbox.id)

    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, queued.id)
    assert {:ok, _other} = Outbound.queue_draft(other_mailbox.id, other_queued.id)

    assert [summary] = Outbound.list_sent(mailbox.id)
    assert summary.id == queued.id
    assert summary.state == "queued"
    assert summary.recipients == ["person@example.net"]
    refute summary.id == draft.id
  end

  test "loads mailbox-scoped draft details through a public projection" do
    %{mailbox: mailbox, address: sender_address} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()

    draft =
      draft_fixture(mailbox.id)

    assert {:ok, detail} = Outbound.get_draft(mailbox.id, draft.id)
    assert detail.id == draft.id
    assert detail.sender_address == sender_address
    assert detail.subject == "Ready"
    assert detail.text_body == "Body"
    assert detail.lock_version == draft.lock_version
    assert [%{kind: "to", address: "person@example.net"}] = detail.recipients

    assert {:error, %{reason: :draft_not_found}} =
             Outbound.get_draft(other_mailbox.id, draft.id)
  end

  test "loads sent detail with recipient, submission, and audit projections" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")
    draft = draft_fixture(mailbox.id)
    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)

    assert {:ok, detail} = Outbound.get_sent(mailbox.id, queued.id)
    assert detail.id == queued.id
    assert detail.state == "queued"
    assert detail.subject == "Ready"
    assert [%{kind: "to", delivery_state: "pending"}] = detail.recipients
    assert detail.submission.provider == "gmail"
    assert detail.submission.state == "pending"
    assert Enum.map(detail.events, & &1.event_type) == ["draft_created", "queued"]

    assert {:error, %{reason: :sent_not_found}} =
             Outbound.get_sent(other_mailbox.id, queued.id)

    assert {:error, %{reason: :sent_not_found}} =
             Outbound.get_sent(mailbox.id, draft_fixture(mailbox.id).id)
  end

  defp draft_fixture(mailbox_id, opts \\ []) do
    recipients =
      [%{kind: "to", address: "person@example.net"}] ++
        if Keyword.get(opts, :include_bcc, false) do
          [%{kind: "bcc", address: "hidden@example.net"}]
        else
          []
        end

    {:ok, draft} =
      Outbound.create_draft(mailbox_id, %{
        subject: "Ready",
        text_body: "Body",
        recipients: recipients
      })

    draft
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "outbound#{suffix}.test"})

    {:ok, mailbox} =
      Accounts.create_account(domain, %{local_part: "inbox", name: "Local Inbox"})

    %{mailbox: mailbox, address: "inbox@#{domain.normalized_domain}"}
  end

  defp send_method_fixture(account_id, address, kind) do
    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: account_id,
      kind: kind,
      email_address: address,
      status: "connected",
      enabled: true
    })
    |> Repo.insert!()
  end

  defp expected_raw(message, provider, idempotency_key) do
    recipients = Outbound.list_recipients(message.id)

    envelope = %Envelope{
      from: mailbox(message.sender_name, message.sender_address),
      to: recipient_mailboxes(recipients, "to"),
      cc: recipient_mailboxes(recipients, "cc"),
      bcc: recipient_mailboxes(recipients, "bcc"),
      subject: message.subject,
      text: message.text_body || "",
      message_id: "<#{message.id}@manifold.local>",
      queued_at: message.queued_at,
      in_reply_to: message.in_reply_to,
      references: message.references,
      idempotency_key: idempotency_key
    }

    RfcMessage.render!(envelope,
      provider: String.to_existing_atom(provider),
      message_id: envelope.message_id,
      date: envelope.queued_at
    )
  end

  defp recipient_mailboxes(recipients, kind) do
    recipients
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(&mailbox(&1.display_name, &1.address))
  end

  defp mailbox(nil, address), do: address
  defp mailbox("", address), do: address
  defp mailbox(display_name, address), do: "#{display_name} <#{address}>"

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
