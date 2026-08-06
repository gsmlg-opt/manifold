defmodule Manifold.Connectors.Schema.SendCredential do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  schema "connector_send_credentials" do
    field(:send_method_id, :binary_id)
    field(:key_version, :integer, default: 1)
    field(:password_ciphertext, :binary)
    field(:lock_version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:send_method_id, :key_version, :password_ciphertext])
    |> validate_required([:send_method_id, :key_version, :password_ciphertext])
    |> unique_constraint(:send_method_id)
    |> optimistic_lock(:lock_version)
  end
end
