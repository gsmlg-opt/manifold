defmodule Manifold.Repo.Migrations.AddAccountRouteRevision do
  use Ecto.Migration

  def change do
    create table(:account_route_revisions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:revision, :bigint, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      """
      INSERT INTO account_route_revisions (id, revision, inserted_at, updated_at)
      VALUES ('00000000-0000-0000-0000-000000000001', 0, NOW(), NOW())
      """,
      "DELETE FROM account_route_revisions"
    )
  end
end
