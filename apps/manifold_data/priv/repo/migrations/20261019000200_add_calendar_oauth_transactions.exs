defmodule Manifold.Repo.Migrations.AddCalendarOAuthTransactions do
  use Ecto.Migration

  def change do
    create table(:calendar_oauth_transactions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:state_digest, :binary, null: false)
      add(:verifier_ciphertext, :binary, null: false)
      add(:redirect_uri, :text, null: false)
      add(:setting_id, :binary_id, null: false)
      add(:setting_version, :integer, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:calendar_oauth_transactions, [:state_digest]))
  end
end
