defmodule Manifold.Connectors.Schema.OAuthTransaction do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  schema "connector_oauth_transactions" do
    field(:state_digest, :binary)
    field(:provider, :string)
    field(:mailbox_id, :binary_id)
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
      :pkce_verifier_ciphertext,
      :redirect_uri,
      :expires_at,
      :consumed_at
    ])
    |> validate_required([
      :state_digest,
      :provider,
      :mailbox_id,
      :pkce_verifier_ciphertext,
      :redirect_uri,
      :expires_at
    ])
    |> validate_inclusion(:provider, ["gmail", "microsoft"])
    |> validate_length(:redirect_uri, max: 2_048)
    |> unique_constraint(:state_digest)
  end
end
