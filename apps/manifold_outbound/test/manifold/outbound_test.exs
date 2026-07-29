defmodule Manifold.OutboundTest do
  use Manifold.DataCase, async: true

  alias Manifold.Accounts
  alias Manifold.Outbound
  alias Manifold.Outbound.Jobs.SubmitOutbound

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
                 %{kind: "to", address: "First@Example.net", display_name: "First"},
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
    %{mailbox: mailbox} = mailbox_fixture()
    draft = draft_fixture(mailbox.id)

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
             provider: "resend",
             state: "pending",
             idempotency_key: idempotency_key,
             request_sha256: request_sha256,
             idempotency_expires_at: %DateTime{}
           } = Repo.one!(ProviderSubmission)

    assert byte_size(idempotency_key) > 0
    assert byte_size(request_sha256) == 64
    assert Repo.get_by!(OutboundEvent, outbound_message_id: draft.id, event_type: "queued")

    assert {:ok, repeated} = Outbound.queue_draft(mailbox.id, draft.id)
    assert repeated.id == draft.id
    assert Repo.aggregate(Oban.Job, :count) == 1
    assert Repo.aggregate(ProviderSubmission, :count) == 1

    assert {:error, %{reason: :message_not_editable}} =
             Outbound.update_draft(mailbox.id, draft.id, %{subject: "Too late"})
  end

  test "queue transaction failure rolls back state and job insertion" do
    %{mailbox: mailbox} = mailbox_fixture()
    draft = draft_fixture(mailbox.id)

    assert {:error, %{reason: :after_queue_before_job}} =
             Outbound.queue_draft(mailbox.id, draft.id, fail_at: :after_queue_before_job)

    assert Repo.get!(OutboundMessage, draft.id).state == "draft"
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(ProviderSubmission, :count) == 0
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
    %{mailbox: mailbox} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()
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
    %{mailbox: mailbox} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()
    draft = draft_fixture(mailbox.id)
    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)

    assert {:ok, detail} = Outbound.get_sent(mailbox.id, queued.id)
    assert detail.id == queued.id
    assert detail.state == "queued"
    assert detail.subject == "Ready"
    assert [%{kind: "to", delivery_state: "pending"}] = detail.recipients
    assert detail.submission.provider == "resend"
    assert detail.submission.state == "pending"
    assert Enum.map(detail.events, & &1.event_type) == ["draft_created", "queued"]

    assert {:error, %{reason: :sent_not_found}} =
             Outbound.get_sent(other_mailbox.id, queued.id)

    assert {:error, %{reason: :sent_not_found}} =
             Outbound.get_sent(mailbox.id, draft_fixture(mailbox.id).id)
  end

  defp draft_fixture(mailbox_id) do
    {:ok, draft} =
      Outbound.create_draft(mailbox_id, %{
        subject: "Ready",
        text_body: "Body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    draft
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "outbound#{suffix}.test"})

    {:ok, mailbox} =
      Accounts.create_mailbox(domain, %{local_part: "inbox", display_name: "Local Inbox"})

    %{mailbox: mailbox, address: "inbox@#{domain.normalized_domain}"}
  end
end
