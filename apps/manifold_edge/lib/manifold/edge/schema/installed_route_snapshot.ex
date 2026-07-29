defmodule Manifold.Edge.Schema.InstalledRouteSnapshot do
  @moduledoc false

  use Manifold.Edge.Schema
  import Ecto.Changeset

  schema "edge_route_snapshots" do
    field(:schema_version, :integer)
    field(:revision, :integer)
    field(:digest, :string)
    field(:generated_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:installed_at, :utc_datetime_usec)
    field(:active, :boolean, default: false)

    has_many(:routes, Manifold.Edge.Schema.InstalledRoute,
      foreign_key: :route_snapshot_id,
      preload_order: [asc: :position]
    )

    timestamps(type: :utc_datetime_usec)
  end

  @spec install_changeset(t(), map()) :: Ecto.Changeset.t()
  def install_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :schema_version,
      :revision,
      :digest,
      :generated_at,
      :expires_at,
      :installed_at,
      :active
    ])
    |> validate_required([
      :schema_version,
      :revision,
      :digest,
      :generated_at,
      :expires_at,
      :installed_at,
      :active
    ])
    |> validate_number(:schema_version, greater_than: 0)
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> validate_format(:digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:revision)
  end
end
