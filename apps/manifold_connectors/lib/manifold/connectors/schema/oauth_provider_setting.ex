defmodule Manifold.Connectors.Schema.OAuthProviderSetting do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  schema "connector_oauth_provider_settings" do
    field(:provider, :string)
    field(:client_id, :string)
    field(:auth_flow, :string, default: "authorization_code")
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
      :auth_flow,
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
      :auth_flow,
      :key_version,
      :lock_version
    ])
    |> validate_inclusion(:auth_flow, ["authorization_code", "device_code"])
    |> validate_flow_secret()
    |> validate_number(:key_version, greater_than: 0)
    |> validate_number(:lock_version, greater_than: 0)
    |> unique_constraint(:provider)
    |> check_constraint(:provider, name: :oauth_provider_settings_provider_present)
    |> check_constraint(:client_id, name: :oauth_provider_settings_client_id_present)
    |> check_constraint(:key_version, name: :oauth_provider_settings_key_version_positive)
    |> check_constraint(:lock_version, name: :oauth_provider_settings_lock_version_positive)
    |> check_constraint(:auth_flow, name: :oauth_provider_settings_auth_flow_valid)
    |> check_constraint(:client_secret_ciphertext,
      name: :oauth_provider_settings_flow_secret_valid
    )
  end

  defp validate_flow_secret(changeset) do
    case get_field(changeset, :auth_flow) do
      "device_code" ->
        changeset
        |> validate_inclusion(:provider, ["microsoft"])
        |> validate_change(:client_secret_ciphertext, fn _, ciphertext ->
          if is_nil(ciphertext), do: [], else: [client_secret_ciphertext: "must be blank"]
        end)

      _code ->
        validate_required(changeset, :client_secret_ciphertext)
    end
  end
end
