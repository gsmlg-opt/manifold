defmodule Manifold.Connectors.Schema.OAuthAuthorization do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  @providers ~w(gmail)
  @statuses ~w(connected reconnect_required disconnected)

  schema "connector_oauth_authorizations" do
    field(:account_id, :binary_id, source: :mailbox_id)
    field(:provider, :string)
    field(:provider_subject_id, :string)
    field(:email_address, :string)
    field(:granted_scopes, {:array, :string}, default: [])
    field(:status, :string, default: "connected")
    field(:key_version, :integer, default: 1)
    field(:access_token_ciphertext, :binary)
    field(:refresh_token_ciphertext, :binary)
    field(:token_expires_at, :utc_datetime_usec)
    field(:last_error_class, :string)
    field(:last_error_code, :string)
    field(:last_error_message, :string)
    field(:disconnected_at, :utc_datetime_usec)
    field(:lock_version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(authorization, attrs) do
    authorization
    |> cast(attrs, [
      :account_id,
      :provider,
      :provider_subject_id,
      :email_address,
      :granted_scopes,
      :status,
      :key_version,
      :access_token_ciphertext,
      :refresh_token_ciphertext,
      :token_expires_at,
      :last_error_class,
      :last_error_code,
      :last_error_message,
      :disconnected_at
    ])
    |> update_change(:granted_scopes, &normalize_scopes/1)
    |> validate_required([
      :account_id,
      :provider,
      :provider_subject_id,
      :email_address,
      :granted_scopes,
      :status,
      :key_version
    ])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:provider_subject_id, min: 1, max: 255)
    |> validate_length(:email_address, min: 3, max: 998)
    |> validate_length(:last_error_class, max: 255)
    |> validate_length(:last_error_code, max: 255)
    |> validate_length(:last_error_message, max: 1_000)
    |> maybe_require_refresh_token()
    |> foreign_key_constraint(:account_id,
      name: :connector_oauth_authorizations_mailbox_id_fkey
    )
    |> unique_constraint([:account_id, :provider],
      name: :connector_oauth_authorizations_mailbox_id_provider_index
    )
    |> unique_constraint([:provider, :provider_subject_id],
      name: :connector_oauth_authorizations_provider_subject_index
    )
    |> optimistic_lock(:lock_version)
  end

  defp maybe_require_refresh_token(changeset) do
    if get_field(changeset, :status) == "connected" do
      validate_required(changeset, [:refresh_token_ciphertext])
    else
      changeset
    end
  end

  defp normalize_scopes(scopes) when is_list(scopes), do: scopes |> Enum.uniq() |> Enum.sort()
  defp normalize_scopes(scopes), do: scopes
end
