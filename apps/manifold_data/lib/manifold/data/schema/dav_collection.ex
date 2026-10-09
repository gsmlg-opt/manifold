defmodule Manifold.Data.Schema.DAVCollection do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "dav_collections" do
    field(:kind, :string)
    field(:href, :string)
    field(:name, :string)
    field(:sync_token, :string)
    belongs_to(:connection, Manifold.Data.Schema.ICloudConnection)
    has_many(:contacts, Manifold.Data.Schema.Contact, foreign_key: :collection_id)
    has_many(:events, Manifold.Data.Schema.CalendarEvent, foreign_key: :collection_id)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:connection_id, :kind, :href, :name, :sync_token])
    |> validate_required([:connection_id, :kind, :href])
    |> validate_inclusion(:kind, ["contacts", "calendars"])
    |> foreign_key_constraint(:connection_id)
    |> unique_constraint([:connection_id, :kind, :href], error_key: :href)
    |> check_constraint(:kind, name: :dav_collections_kind_valid)
    |> check_constraint(:href, name: :dav_collections_href_present)
  end
end
