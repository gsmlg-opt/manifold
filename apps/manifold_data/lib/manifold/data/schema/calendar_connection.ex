defmodule Manifold.Data.Schema.CalendarConnection do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "calendar_connections" do
    field :provider, :string
    field :remote_identity, :string
    field :identity_verified_at, :utc_datetime_usec
    field :display_name, :string
    field :credential_context, :string
    field :encrypted_credentials, :binary, redact: true
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime_usec
    field :status, :string, default: "paused"
    field :generation, :integer, default: 1
    field :legacy_connection_id, :binary_id
    field :provider_metadata, :map, default: %{}
    has_many :bindings, Manifold.Data.Schema.CalendarBinding, foreign_key: :connection_id
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(
      attrs,
      [
        :provider,
        :remote_identity,
        :identity_verified_at,
        :display_name,
        :credential_context,
        :encrypted_credentials,
        :scopes,
        :expires_at,
        :status,
        :generation,
        :legacy_connection_id,
        :provider_metadata
      ],
      empty_values: []
    )
    |> validate_required([:provider, :status, :generation])
    |> validate_inclusion(:provider, ~w(google icloud))
    |> validate_inclusion(:status, ~w(active paused reconnect_required))
    |> validate_number(:generation, greater_than: 0)
    |> unique_constraint([:provider, :remote_identity])
    |> unique_constraint(:legacy_connection_id)
  end
end
