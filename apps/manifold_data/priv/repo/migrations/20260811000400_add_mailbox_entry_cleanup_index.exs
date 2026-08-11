defmodule Manifold.Repo.Migrations.AddMailboxEntryCleanupIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    drop_if_exists(index(:mailbox_entries, [:mailbox_id, :id], concurrently: true))
    create(index(:mailbox_entries, [:mailbox_id, :id], concurrently: true))
  end

  def down do
    drop_if_exists(index(:mailbox_entries, [:mailbox_id, :id], concurrently: true))
  end
end
