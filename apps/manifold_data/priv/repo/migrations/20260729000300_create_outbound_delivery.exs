defmodule Manifold.Repo.Migrations.CreateOutboundDelivery do
  use Ecto.Migration

  def change do
    create table(:outbound_messages, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:state, :text, null: false, default: "draft")
      add(:composition_kind, :text, null: false, default: "new")

      add(
        :source_message_id,
        references(:messages, type: :binary_id, on_delete: :nilify_all)
      )

      add(:sender_name, :text)
      add(:sender_address, :text, null: false)
      add(:canonical_sender_address, :text, null: false)
      add(:subject, :text)
      add(:text_body, :text)
      add(:in_reply_to, :text)
      add(:references, {:array, :text}, null: false, default: [])
      add(:last_error_class, :text)
      add(:last_error_code, :text)
      add(:last_error_message, :text)
      add(:lock_version, :integer, null: false, default: 1)
      add(:queued_at, :utc_datetime_usec)
      add(:accepted_at, :utc_datetime_usec)
      add(:failed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:outbound_messages, [:mailbox_id, :state, :updated_at]))

    create(
      constraint(:outbound_messages, :outbound_messages_state_valid,
        check:
          "state IN ('draft', 'queued', 'submitting', 'accepted_by_provider', 'failed', 'submission_uncertain')"
      )
    )

    create(
      constraint(:outbound_messages, :outbound_messages_composition_kind_valid,
        check: "composition_kind IN ('new', 'reply', 'reply_all', 'forward')"
      )
    )

    create(
      constraint(:outbound_messages, :outbound_messages_subject_size,
        check: "subject IS NULL OR octet_length(subject) <= 998"
      )
    )

    create(
      constraint(:outbound_messages, :outbound_messages_body_size,
        check: "text_body IS NULL OR octet_length(text_body) <= 10485760"
      )
    )

    create(
      constraint(:outbound_messages, :outbound_messages_lock_version_positive,
        check: "lock_version > 0"
      )
    )

    create(
      constraint(:outbound_messages, :outbound_messages_queued_at_required,
        check: "state = 'draft' OR queued_at IS NOT NULL"
      )
    )

    create(
      constraint(:outbound_messages, :outbound_messages_accepted_at_required,
        check: "state != 'accepted_by_provider' OR accepted_at IS NOT NULL"
      )
    )

    create table(:outbound_recipients, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :outbound_message_id,
        references(:outbound_messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:position, :integer, null: false)
      add(:display_name, :text)
      add(:address, :text, null: false)
      add(:canonical_address, :text, null: false)
      add(:delivery_state, :text, null: false, default: "pending")
      add(:last_event_at, :utc_datetime_usec)
      add(:status_detail, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:outbound_recipients, [:outbound_message_id, :kind, :position]))
    create(unique_index(:outbound_recipients, [:outbound_message_id, :canonical_address]))

    create(
      constraint(:outbound_recipients, :outbound_recipients_kind_valid,
        check: "kind IN ('to', 'cc', 'bcc')"
      )
    )

    create(
      constraint(:outbound_recipients, :outbound_recipients_position_nonnegative,
        check: "position >= 0"
      )
    )

    create(
      constraint(:outbound_recipients, :outbound_recipients_delivery_state_valid,
        check:
          "delivery_state IN ('pending', 'sent', 'delayed', 'delivered', 'bounced', 'failed', 'suppressed', 'complained')"
      )
    )

    create table(:provider_submissions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :outbound_message_id,
        references(:outbound_messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:provider, :text, null: false)
      add(:idempotency_key, :text, null: false)
      add(:request_sha256, :text, null: false)
      add(:state, :text, null: false, default: "pending")
      add(:attempt_count, :integer, null: false, default: 0)
      add(:provider_message_id, :text)
      add(:provider_rfc_message_id, :text)
      add(:first_attempt_at, :utc_datetime_usec)
      add(:last_attempt_at, :utc_datetime_usec)
      add(:accepted_at, :utc_datetime_usec)
      add(:idempotency_expires_at, :utc_datetime_usec, null: false)
      add(:last_http_status, :integer)
      add(:last_error_code, :text)
      add(:last_error_message, :text)
      add(:provider_metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:provider_submissions, [:outbound_message_id]))
    create(unique_index(:provider_submissions, [:provider, :idempotency_key]))

    create(
      unique_index(:provider_submissions, [:provider, :provider_message_id],
        where: "provider_message_id IS NOT NULL"
      )
    )

    create(
      constraint(:provider_submissions, :provider_submissions_attempt_nonnegative,
        check: "attempt_count >= 0"
      )
    )

    create(
      constraint(:provider_submissions, :provider_submissions_state_valid,
        check: "state IN ('pending', 'submitting', 'accepted', 'failed', 'uncertain')"
      )
    )

    create(
      constraint(:provider_submissions, :provider_submissions_request_sha256_valid,
        check: "request_sha256 ~ '^[0-9a-f]{64}$'"
      )
    )

    create(
      constraint(:provider_submissions, :provider_submissions_idempotency_key_size,
        check: "octet_length(idempotency_key) BETWEEN 1 AND 256"
      )
    )

    create table(:provider_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :outbound_message_id,
        references(:outbound_messages, type: :binary_id, on_delete: :nilify_all)
      )

      add(:provider, :text, null: false)
      add(:provider_event_id, :text, null: false)
      add(:provider_message_id, :text, null: false)
      add(:event_type, :text, null: false)
      add(:normalized_state, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:received_at, :utc_datetime_usec, null: false)
      add(:processing_state, :text, null: false, default: "pending")
      add(:processed_at, :utc_datetime_usec)
      add(:last_error, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:provider_events, [:provider, :provider_event_id]))
    create(index(:provider_events, [:provider, :provider_message_id]))
    create(index(:provider_events, [:outbound_message_id, :occurred_at]))

    create(
      constraint(:provider_events, :provider_events_processing_state_valid,
        check: "processing_state IN ('pending', 'processed', 'unmatched', 'failed')"
      )
    )

    create table(:outbound_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :outbound_message_id,
        references(:outbound_messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:event_type, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:occurred_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:outbound_events, [:outbound_message_id, :occurred_at]))
  end
end
