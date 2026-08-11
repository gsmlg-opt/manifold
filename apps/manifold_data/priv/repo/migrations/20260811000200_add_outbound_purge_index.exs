defmodule Manifold.Repo.Migrations.AddOutboundPurgeIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(index(:outbound_messages, [:mailbox_id, :id], concurrently: true))
  end
end
