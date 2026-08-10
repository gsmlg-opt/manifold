defmodule Manifold.Repo.Migrations.AddIngestCleanupIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(
      index(:inbound_deliveries, [:raw_object_key],
        where: "raw_object_key IS NOT NULL",
        concurrently: true
      )
    )

    create(index(:inbound_deliveries, [:spool_bundle_path], concurrently: true))
  end
end
