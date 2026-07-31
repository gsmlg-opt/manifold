defmodule Manifold.Connectors.Schema.OAuthTransaction do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  schema "connector_oauth_transactions" do
    field(:state_digest, :binary)
    field(:provider, :string)
    field(:mailbox_id, :binary_id)
    field(:flow, :string, default: "authorization_code")
    field(:pkce_verifier_ciphertext, :binary)
    field(:device_code_ciphertext, :binary)
    field(:user_code, :string)
    field(:verification_uri, :string)
    field(:verification_uri_complete, :string)
    field(:interval_seconds, :integer)
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
      :flow,
      :pkce_verifier_ciphertext,
      :device_code_ciphertext,
      :user_code,
      :verification_uri,
      :verification_uri_complete,
      :interval_seconds,
      :redirect_uri,
      :expires_at,
      :consumed_at
    ])
    |> validate_required([:state_digest, :provider, :mailbox_id, :flow, :expires_at])
    |> validate_inclusion(:provider, ["gmail", "microsoft"])
    |> validate_inclusion(:flow, ["authorization_code", "device"])
    |> validate_length(:redirect_uri, max: 2_048)
    |> validate_length(:verification_uri, max: 2_048)
    |> validate_length(:verification_uri_complete, max: 2_048)
    |> validate_length(:user_code, max: 64)
    |> validate_number(:interval_seconds, greater_than: 0)
    |> validate_flow_fields()
    |> unique_constraint(:state_digest)
  end

  defp validate_flow_fields(changeset) do
    case get_field(changeset, :flow) do
      "authorization_code" ->
        changeset
        |> validate_required([:pkce_verifier_ciphertext, :redirect_uri])

      "device" ->
        changeset
        |> validate_required([
          :device_code_ciphertext,
          :user_code,
          :verification_uri,
          :interval_seconds
        ])

      _other ->
        changeset
    end
  end
end
