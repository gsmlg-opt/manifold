defmodule Manifold.Repo.Migrations.AddAttachmentObjectKeyIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(index(:attachments, [:object_key], concurrently: true))
    create(index(:mailbox_entries, [:mailbox_id, :id], concurrently: true))
  end
end
