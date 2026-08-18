defmodule Manifold.Connectors.Schema.OAuthTransaction do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  schema "connector_oauth_transactions" do
    field(:state_digest, :binary)
    field(:provider, :string)
    field(:mailbox_id, :binary_id)
    field(:purpose, :string, default: "receive")
    field(:required_scopes, {:array, :string}, default: [])
    field(:pkce_verifier_ciphertext, :binary)
    field(:redirect_uri, :string)
    field(:oauth_provider_setting_id, :binary_id)
    field(:oauth_provider_setting_lock_version, :integer)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :state_digest,
      :provider,
      :mailbox_id,
      :purpose,
      :required_scopes,
      :pkce_verifier_ciphertext,
      :redirect_uri,
      :oauth_provider_setting_id,
      :oauth_provider_setting_lock_version,
      :expires_at,
      :consumed_at
    ])
    |> validate_required([
      :state_digest,
      :provider,
      :mailbox_id,
      :purpose,
      :required_scopes,
      :pkce_verifier_ciphertext,
      :redirect_uri,
      :expires_at
    ])
    |> update_change(:required_scopes, &normalize_scopes/1)
    |> validate_inclusion(:provider, ["gmail", "microsoft"])
    |> validate_inclusion(:purpose, ["receive", "send"])
    |> validate_length(:redirect_uri, max: 2_048)
    |> validate_change(:oauth_provider_setting_id, fn _, setting_id ->
      if Ecto.UUID.cast(setting_id) == :error,
        do: [oauth_provider_setting_id: "is invalid"],
        else: []
    end)
    |> validate_number(:oauth_provider_setting_lock_version, greater_than: 0)
    |> validate_setting_generation()
    |> check_constraint(:oauth_provider_setting_id,
      name: :oauth_transaction_setting_generation_valid
    )
    |> check_constraint(:oauth_provider_setting_lock_version,
      name: :oauth_transaction_setting_lock_version_positive
    )
    |> unique_constraint(:state_digest)
  end

  defp validate_setting_generation(changeset) do
    if Keyword.has_key?(changeset.errors, :oauth_provider_setting_id) or
         Keyword.has_key?(changeset.errors, :oauth_provider_setting_lock_version) do
      changeset
    else
      case {
        get_field(changeset, :oauth_provider_setting_id),
        get_field(changeset, :oauth_provider_setting_lock_version)
      } do
        {nil, nil} ->
          changeset

        {nil, _lock_version} ->
          add_error(
            changeset,
            :oauth_provider_setting_id,
            "must be present with OAuth provider setting lock version"
          )

        {_setting_id, nil} ->
          add_error(
            changeset,
            :oauth_provider_setting_lock_version,
            "must be present with OAuth provider setting"
          )

        {_setting_id, _lock_version} ->
          changeset
      end
    end
  end

  defp normalize_scopes(scopes) when is_list(scopes), do: scopes |> Enum.uniq() |> Enum.sort()
  defp normalize_scopes(scopes), do: scopes
end
