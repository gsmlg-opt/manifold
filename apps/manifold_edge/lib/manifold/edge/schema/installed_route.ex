defmodule Manifold.Edge.Schema.InstalledRoute do
  @moduledoc false

  use Manifold.Edge.Schema
  import Ecto.Changeset

  schema "edge_routes" do
    field(:position, :integer)
    field(:canonical_address, :string)
    field(:domain_id, :string)
    field(:mailbox_ids, {:array, :string}, default: [])
    field(:plus_addressing_enabled, :boolean, default: false)

    belongs_to(:route_snapshot, Manifold.Edge.Schema.InstalledRouteSnapshot)

    timestamps(type: :utc_datetime_usec)
  end

  @spec install_changeset(t(), map()) :: Ecto.Changeset.t()
  def install_changeset(route, attrs) do
    route
    |> cast(attrs, [
      :route_snapshot_id,
      :position,
      :canonical_address,
      :domain_id,
      :mailbox_ids,
      :plus_addressing_enabled
    ])
    |> validate_required([
      :position,
      :canonical_address,
      :domain_id,
      :mailbox_ids,
      :plus_addressing_enabled
    ])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_length(:mailbox_ids, min: 1)
    |> unique_constraint([:route_snapshot_id, :canonical_address])
    |> unique_constraint([:route_snapshot_id, :position])
  end
end
