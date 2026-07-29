defmodule Manifold.Repo.Migrations.DropOwners do
  use Ecto.Migration

  def up do
    drop(table(:owners))
  end

  def down do
    create table(:owners, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:email, :citext, null: false)
      add(:hashed_password, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:owners, [:email]))
  end
end
