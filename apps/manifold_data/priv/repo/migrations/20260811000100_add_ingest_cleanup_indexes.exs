defmodule Manifold.Repo.Migrations.AddIngestCleanupIndexes do
  use Ecto.Migration

  def change do
    create(index(:inbound_deliveries, [:raw_object_key], where: "raw_object_key IS NOT NULL"))

    create(index(:inbound_deliveries, [:spool_bundle_path]))
  end
end
