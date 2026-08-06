defmodule Manifold.Repo.Migrations.AddEasConnectorSupport do
  use Ecto.Migration

  def up do
    create table(:connector_eas_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :external_account_id,
        references(:connector_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:host, :text, null: false)
      add(:port, :integer, null: false)
      add(:path, :text, null: false, default: "/Microsoft-Server-ActiveSync")
      add(:username, :text, null: false)
      add(:device_id, :text, null: false)
      add(:device_type, :text, null: false, default: "Manifold")
      add(:protocol_version, :text, null: false, default: "14.1")
      add(:policy_key, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:connector_eas_settings, [:external_account_id]))

    create(
      constraint(:connector_eas_settings, :connector_eas_settings_port_valid,
        check: "port > 0 AND port <= 65535"
      )
    )
  end

  def down do
    drop(table(:connector_eas_settings))
  end
end
