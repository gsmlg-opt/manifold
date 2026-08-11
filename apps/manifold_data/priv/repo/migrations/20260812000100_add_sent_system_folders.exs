defmodule Manifold.Repo.Migrations.AddSentSystemFolders do
  use Ecto.Migration

  def up do
    drop(constraint(:mailbox_folders, :mailbox_folders_kind_valid))

    create(
      constraint(:mailbox_folders, :mailbox_folders_kind_valid,
        check: "kind IN ('inbox', 'archive', 'sent', 'trash', 'custom')"
      )
    )

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM mailbox_folders AS custom_sent
        JOIN mailbox_folders AS conflict
          ON conflict.mailbox_id = custom_sent.mailbox_id
         AND conflict.id <> custom_sent.id
         AND conflict.normalized_name =
           lower('Sent (custom ' || custom_sent.id::text || ')')
        WHERE custom_sent.kind = 'custom'
          AND custom_sent.normalized_name = 'sent'
      ) THEN
        RAISE EXCEPTION 'cannot reserve Sent because the deterministic custom-folder name is occupied';
      END IF;
    END
    $$
    """)

    execute("""
    UPDATE mailbox_folders
    SET name = 'Sent (custom ' || id::text || ')',
        normalized_name = lower('Sent (custom ' || id::text || ')'),
        updated_at = NOW()
    WHERE kind = 'custom' AND normalized_name = 'sent'
    """)

    execute("""
    INSERT INTO mailbox_folders
      (id, mailbox_id, kind, name, normalized_name, inserted_at, updated_at)
    SELECT gen_random_uuid(), mailbox.id, 'sent', 'Sent', 'sent', NOW(), NOW()
    FROM mailboxes AS mailbox
    WHERE NOT EXISTS (
      SELECT 1 FROM mailbox_folders AS folder
      WHERE folder.mailbox_id = mailbox.id AND folder.kind = 'sent'
    )
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM mailbox_entries AS entry
        JOIN mailbox_folders AS folder
          ON folder.id = entry.folder_id OR folder.id = entry.previous_folder_id
        WHERE folder.kind = 'sent'
      ) THEN
        RAISE EXCEPTION 'cannot rollback Sent folders while Sent contains mailbox entries';
      END IF;
    END
    $$
    """)

    execute("DELETE FROM mailbox_folders WHERE kind = 'sent'")

    execute("""
    UPDATE mailbox_folders
    SET name = 'Sent', normalized_name = 'sent', updated_at = NOW()
    WHERE kind = 'custom'
      AND name = 'Sent (custom ' || id::text || ')'
      AND normalized_name = lower('Sent (custom ' || id::text || ')')
    """)

    drop(constraint(:mailbox_folders, :mailbox_folders_kind_valid))

    create(
      constraint(:mailbox_folders, :mailbox_folders_kind_valid,
        check: "kind IN ('inbox', 'archive', 'trash', 'custom')"
      )
    )
  end
end
