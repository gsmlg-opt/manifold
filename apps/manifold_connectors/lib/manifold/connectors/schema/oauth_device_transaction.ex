defmodule Manifold.Connectors.Schema.OAuthDeviceTransaction do
  @moduledoc false
  use Manifold.Connectors.Schema

  schema "connector_oauth_device_transactions" do
    field(:account_id, :binary_id)
    field(:purpose, :string)
    field(:required_scopes, {:array, :string})
    field(:oauth_provider_setting_id, :binary_id)
    field(:oauth_provider_setting_lock_version, :integer)
    field(:device_code_ciphertext, :binary, redact: true)
    field(:user_code, :string)
    field(:verification_uri, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:interval, :integer)
    field(:next_poll_at, :utc_datetime_usec)
    field(:status, :string, default: "pending")
    field(:claim_id, :binary_id)
    field(:claim_expires_at, :utc_datetime_usec)
    timestamps()
  end
end
