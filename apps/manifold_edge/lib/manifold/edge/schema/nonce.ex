defmodule Manifold.Edge.Schema.Nonce do
  @moduledoc false

  use Manifold.Edge.Schema
  import Ecto.Changeset

  schema "edge_signature_nonces" do
    field(:key_id, :string)
    field(:nonce_digest, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:claimed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec claim_changeset(t(), map()) :: Ecto.Changeset.t()
  def claim_changeset(nonce, attrs) do
    nonce
    |> cast(attrs, [:key_id, :nonce_digest, :expires_at, :claimed_at])
    |> validate_required([:key_id, :nonce_digest, :expires_at, :claimed_at])
    |> validate_length(:key_id, min: 1, max: 255)
    |> validate_format(:nonce_digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint([:key_id, :nonce_digest])
  end
end
