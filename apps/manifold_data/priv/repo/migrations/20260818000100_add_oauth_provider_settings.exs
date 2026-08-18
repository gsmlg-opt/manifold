defmodule Manifold.Repo.Migrations.AddOAuthProviderSettings do
  use Ecto.Migration

  def up do
    create table(:connector_oauth_provider_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:provider, :text, null: false)
      add(:client_id, :text, null: false)
      add(:client_secret_ciphertext, :binary, null: false)
      add(:key_version, :integer, null: false, default: 1)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:connector_oauth_provider_settings, [:provider]))

    create(
      constraint(:connector_oauth_provider_settings, :oauth_provider_settings_provider_present,
        check: "length(btrim(provider)) > 0"
      )
    )

    create(
      constraint(:connector_oauth_provider_settings, :oauth_provider_settings_client_id_present,
        check: "length(btrim(client_id)) > 0"
      )
    )

    create(
      constraint(
        :connector_oauth_provider_settings,
        :oauth_provider_settings_key_version_positive,
        check: "key_version > 0"
      )
    )

    create(
      constraint(
        :connector_oauth_provider_settings,
        :oauth_provider_settings_lock_version_positive,
        check: "lock_version > 0"
      )
    )

    alter table(:connector_oauth_transactions) do
      add(:oauth_provider_setting_id, :binary_id)
      add(:oauth_provider_setting_lock_version, :integer)
    end

    create(
      constraint(:connector_oauth_transactions, :oauth_transaction_setting_generation_valid,
        check:
          "(oauth_provider_setting_id IS NULL) = " <>
            "(oauth_provider_setting_lock_version IS NULL)"
      )
    )
  end

  def down do
    %{rows: [[settings_count]]} =
      repo().query!("SELECT COUNT(*) FROM connector_oauth_provider_settings", [])

    %{rows: [[transaction_count]]} =
      repo().query!(
        "SELECT COUNT(*) FROM connector_oauth_transactions " <>
          "WHERE oauth_provider_setting_id IS NOT NULL",
        []
      )

    if settings_count > 0 or transaction_count > 0 do
      raise "cannot roll back OAuth provider settings while settings or fenced transactions exist"
    end

    drop(
      constraint(
        :connector_oauth_transactions,
        :oauth_transaction_setting_generation_valid
      )
    )

    alter table(:connector_oauth_transactions) do
      remove(:oauth_provider_setting_lock_version)
      remove(:oauth_provider_setting_id)
    end

    drop(table(:connector_oauth_provider_settings))
  end
end
