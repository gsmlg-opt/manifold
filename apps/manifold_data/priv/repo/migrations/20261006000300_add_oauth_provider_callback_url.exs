defmodule Manifold.Repo.Migrations.AddOAuthProviderCallbackUrl do
  use Ecto.Migration

  def up do
    alter table(:connector_oauth_provider_settings) do
      add(:callback_url, :text)
    end

    create(
      constraint(
        :connector_oauth_provider_settings,
        :oauth_provider_settings_callback_provider_valid,
        check: "callback_url IS NULL OR (provider = 'gmail' AND length(btrim(callback_url)) > 0)"
      )
    )
  end

  def down do
    %{rows: [[count]]} =
      repo().query!(
        "SELECT COUNT(*) FROM connector_oauth_provider_settings WHERE callback_url IS NOT NULL"
      )

    if count > 0 do
      raise Ecto.MigrationError,
            "Cannot remove OAuth callback URL while configured callback URLs exist; clear them before rollback"
    end

    drop(
      constraint(
        :connector_oauth_provider_settings,
        :oauth_provider_settings_callback_provider_valid
      )
    )

    alter table(:connector_oauth_provider_settings) do
      remove(:callback_url)
    end
  end
end
