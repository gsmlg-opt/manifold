defmodule Manifold.Repo.Migrations.AddOAuthProviderAuthFlow do
  use Ecto.Migration

  def up do
    alter table(:connector_oauth_provider_settings) do
      add(:auth_flow, :text, null: false, default: "authorization_code")
      modify(:client_secret_ciphertext, :binary, null: true)
    end

    create(
      constraint(:connector_oauth_provider_settings, :oauth_provider_settings_auth_flow_valid,
        check: "auth_flow IN ('authorization_code', 'device_code')"
      )
    )

    create(
      constraint(:connector_oauth_provider_settings, :oauth_provider_settings_flow_secret_valid,
        check:
          "(auth_flow = 'authorization_code' AND client_secret_ciphertext IS NOT NULL) OR " <>
            "(provider = 'microsoft' AND auth_flow = 'device_code' AND client_secret_ciphertext IS NULL)"
      )
    )
  end

  def down do
    %{rows: [[device_count]]} =
      repo().query!(
        "SELECT COUNT(*) FROM connector_oauth_provider_settings WHERE auth_flow = 'device_code'"
      )

    if device_count > 0 do
      raise Ecto.MigrationError,
            "Cannot roll back OAuth auth flow while device-code settings exist"
    end

    drop(
      constraint(:connector_oauth_provider_settings, :oauth_provider_settings_flow_secret_valid)
    )

    drop(constraint(:connector_oauth_provider_settings, :oauth_provider_settings_auth_flow_valid))

    alter table(:connector_oauth_provider_settings) do
      modify(:client_secret_ciphertext, :binary, null: false)
      remove(:auth_flow)
    end
  end
end
