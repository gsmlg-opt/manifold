defmodule Manifold.Connectors.Schema.OAuthProviderSetting do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  schema "connector_oauth_provider_settings" do
    field(:provider, :string)
    field(:client_id, :string)
    field(:client_secret_ciphertext, :binary, redact: true)
    field(:client_secret, :string, virtual: true, redact: true)
    field(:key_version, :integer, default: 1)
    field(:lock_version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :provider,
      :client_id,
      :client_secret_ciphertext,
      :client_secret,
      :key_version,
      :lock_version
    ])
    |> update_change(:provider, &String.trim/1)
    |> update_change(:client_id, &String.trim/1)
    |> validate_required([
      :provider,
      :client_id,
      :client_secret_ciphertext,
      :key_version,
      :lock_version
    ])
    |> validate_number(:key_version, greater_than: 0)
    |> validate_number(:lock_version, greater_than: 0)
    |> unique_constraint(:provider)
    |> check_constraint(:provider, name: :oauth_provider_settings_provider_present)
    |> check_constraint(:client_id, name: :oauth_provider_settings_client_id_present)
    |> check_constraint(:key_version, name: :oauth_provider_settings_key_version_positive)
    |> check_constraint(:lock_version, name: :oauth_provider_settings_lock_version_positive)
  end
end
