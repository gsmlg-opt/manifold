defmodule Manifold.Repo.Migrations.CreateMailProjection do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :inbound_delivery_id,
        references(:inbound_deliveries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:rfc_message_id, :text)
      add(:in_reply_to, :text)
      add(:references, {:array, :text}, null: false, default: [])
      add(:subject, :text)
      add(:sender_name, :text)
      add(:sender_address, :text)
      add(:sent_at, :utc_datetime_usec)
      add(:text_body, :text)
      add(:sanitized_html, :text)
      add(:parser_version, :integer, null: false)
      add(:sanitizer_version, :integer)
      add(:parse_state, :text, null: false, default: "pending")
      add(:parse_error, :text)

      add(
        :search_document,
        :tsvector,
        generated:
          "ALWAYS AS (to_tsvector('simple', coalesce(subject, '') || ' ' || coalesce(sender_address, '') || ' ' || left(coalesce(text_body, ''), 32768))) STORED"
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:messages, [:inbound_delivery_id]))
    create(index(:messages, [:rfc_message_id]))
    create(index(:messages, [:parse_state]))
    create(index(:messages, [:search_document], using: "GIN"))

    create(constraint(:messages, :messages_parser_version_positive, check: "parser_version > 0"))

    create(
      constraint(:messages, :messages_sanitizer_version_positive,
        check: "sanitizer_version IS NULL OR sanitizer_version > 0"
      )
    )

    create(
      constraint(:messages, :messages_parse_state_valid,
        check: "parse_state IN ('pending', 'parsed', 'fallback', 'failed')"
      )
    )

    create table(:message_headers, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:position, :integer, null: false)
      add(:original_name, :text, null: false)
      add(:normalized_name, :text, null: false)
      add(:unfolded_value, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:message_headers, [:message_id, :position]))
    create(index(:message_headers, [:message_id, :normalized_name]))

    create(
      constraint(:message_headers, :message_headers_position_nonnegative, check: "position >= 0")
    )

    create table(:message_addresses, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:position, :integer, null: false)
      add(:display_name, :text)
      add(:address, :text, null: false)
      add(:canonical_address, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:message_addresses, [:message_id, :kind, :position]))
    create(index(:message_addresses, [:message_id, :address]))

    create(
      constraint(:message_addresses, :message_addresses_kind_valid,
        check: "kind IN ('from', 'sender', 'reply_to', 'to', 'cc', 'bcc')"
      )
    )

    create(
      constraint(:message_addresses, :message_addresses_position_nonnegative,
        check: "position >= 0"
      )
    )

    create table(:attachments, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:part_path, :text, null: false)
      add(:content_id, :text)
      add(:filename, :text)
      add(:media_type, :text, null: false)
      add(:disposition, :text, null: false, default: "unspecified")
      add(:size, :bigint, null: false)
      add(:sha256, :text, null: false)
      add(:object_key, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:attachments, [:message_id, :part_path]))
    create(index(:attachments, [:sha256]))
    create(constraint(:attachments, :attachments_size_nonnegative, check: "size >= 0"))

    create(
      constraint(:attachments, :attachments_disposition_valid,
        check: "disposition IN ('attachment', 'inline', 'unspecified')"
      )
    )

    create table(:mailbox_folders, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:name, :text, null: false)
      add(:normalized_name, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:mailbox_folders, [:mailbox_id, :normalized_name]))

    create(
      unique_index(:mailbox_folders, [:mailbox_id, :kind],
        name: :mailbox_folders_mailbox_id_system_kind_index,
        where: "kind <> 'custom'"
      )
    )

    create(
      constraint(:mailbox_folders, :mailbox_folders_kind_valid,
        check: "kind IN ('inbox', 'archive', 'trash', 'custom')"
      )
    )

    create table(:mail_threads, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:subject_summary, :text)
      add(:last_message_at, :utc_datetime_usec, null: false)
      add(:message_count, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:mail_threads, [:mailbox_id, :last_message_at]))

    create(
      constraint(:mail_threads, :mail_threads_message_count_nonnegative,
        check: "message_count >= 0"
      )
    )

    alter table(:mailbox_entries) do
      remove(:status, :text)
      add(:message_id, references(:messages, type: :binary_id, on_delete: :restrict))
      add(:folder_id, references(:mailbox_folders, type: :binary_id, on_delete: :restrict))

      add(
        :previous_folder_id,
        references(:mailbox_folders, type: :binary_id, on_delete: :restrict)
      )

      add(:thread_id, references(:mail_threads, type: :binary_id, on_delete: :restrict))
      add(:read_at, :utc_datetime_usec)
      add(:starred_at, :utc_datetime_usec)
      add(:quarantined, :boolean, null: false, default: false)
    end

    create(index(:mailbox_entries, [:message_id]))
    create(index(:mailbox_entries, [:mailbox_id, :folder_id, :inserted_at]))
    create(index(:mailbox_entries, [:mailbox_id, :thread_id]))
    create(index(:mailbox_entries, [:mailbox_id, :read_at]))
    create(index(:mailbox_entries, [:mailbox_id, :starred_at]))
  end
end
