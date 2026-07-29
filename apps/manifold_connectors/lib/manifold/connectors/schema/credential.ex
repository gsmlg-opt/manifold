defmodule Manifold.Connectors.Schema.Credential do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  schema "connector_credentials" do
    field(:external_account_id, :binary_id)
    field(:key_version, :integer, default: 1)
    field(:access_token_ciphertext, :binary)
    field(:refresh_token_ciphertext, :binary)
    field(:token_expires_at, :utc_datetime_usec)
    field(:lock_version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :external_account_id,
      :key_version,
      :access_token_ciphertext,
      :refresh_token_ciphertext,
      :token_expires_at
    ])
    |> validate_required([
      :external_account_id,
      :key_version,
      :refresh_token_ciphertext
    ])
    |> unique_constraint(:external_account_id)
    |> optimistic_lock(:lock_version)
  end
end
