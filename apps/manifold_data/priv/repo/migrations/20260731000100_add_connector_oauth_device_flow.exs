defmodule Manifold.Repo.Migrations.AddConnectorOAuthDeviceFlow do
  use Ecto.Migration

  def change do
    alter table(:connector_oauth_transactions) do
      add(:flow, :text, null: false, default: "authorization_code")
      add(:device_code_ciphertext, :binary)
      add(:user_code, :text)
      add(:verification_uri, :text)
      add(:verification_uri_complete, :text)
      add(:interval_seconds, :integer)
      modify(:pkce_verifier_ciphertext, :binary, null: true)
      modify(:redirect_uri, :text, null: true)
    end

    create(constraint(:connector_oauth_transactions, :connector_oauth_flow_check,
      check: "flow IN ('authorization_code', 'device')"
    ))
  end
end
