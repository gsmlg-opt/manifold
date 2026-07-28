defmodule Manifold.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext")

    create table(:owners, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:email, :citext, null: false)
      add(:hashed_password, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:owners, [:email]))

    create table(:domains, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :text, null: false)
      add(:normalized_domain, :text, null: false)
      add(:active, :boolean, null: false, default: true)
      add(:plus_addressing_enabled, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:domains, [:normalized_domain]))

    create table(:mailboxes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:domain_id, references(:domains, type: :binary_id, on_delete: :restrict), null: false)
      add(:local_part, :text, null: false)
      add(:canonical_local_part, :text, null: false)
      add(:display_name, :text)
      add(:active, :boolean, null: false, default: true)
      add(:plus_addressing_enabled, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:mailboxes, [:domain_id, :canonical_local_part]))
    create(index(:mailboxes, [:domain_id, :active]))

    create table(:aliases, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:domain_id, references(:domains, type: :binary_id, on_delete: :restrict), null: false)
      add(:local_part, :text, null: false)
      add(:canonical_local_part, :text, null: false)
      add(:active, :boolean, null: false, default: true)
      add(:plus_addressing_enabled, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:aliases, [:domain_id, :canonical_local_part]))
    create(index(:aliases, [:domain_id, :active]))

    create table(:alias_targets, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:alias_id, references(:aliases, type: :binary_id, on_delete: :delete_all), null: false)

      add(:mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:active, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:alias_targets, [:alias_id, :mailbox_id]))
  end
end
