defmodule Manifold.Connectors.Schema.Credential do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  schema "connector_credentials" do
    field(:external_account_id, :binary_id)
    field(:key_version, :integer, default: 1)
    field(:secret_kind, :string, default: "oauth")
    field(:access_token_ciphertext, :binary)
    field(:refresh_token_ciphertext, :binary)
    field(:password_ciphertext, :binary)
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
      :secret_kind,
      :access_token_ciphertext,
      :refresh_token_ciphertext,
      :password_ciphertext,
      :token_expires_at
    ])
    |> validate_required([
      :external_account_id,
      :key_version,
      :secret_kind
    ])
    |> validate_inclusion(:secret_kind, ~w(oauth password))
    |> maybe_require_secret()
    |> unique_constraint(:external_account_id)
    |> optimistic_lock(:lock_version)
  end

  defp maybe_require_secret(changeset) do
    case get_field(changeset, :secret_kind) do
      "password" ->
        validate_required(changeset, [:password_ciphertext])

      _ ->
        validate_required(changeset, [:refresh_token_ciphertext])
    end
  end
end
