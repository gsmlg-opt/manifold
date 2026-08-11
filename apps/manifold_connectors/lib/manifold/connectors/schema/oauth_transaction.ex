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
    |> unique_constraint(:state_digest)
  end

  defp normalize_scopes(scopes) when is_list(scopes), do: scopes |> Enum.uniq() |> Enum.sort()
  defp normalize_scopes(scopes), do: scopes
end
