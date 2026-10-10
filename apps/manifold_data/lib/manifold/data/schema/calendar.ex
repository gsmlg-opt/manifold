defmodule Manifold.Data.Schema.Calendar do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "calendars" do
    field(:account_id, :binary_id)
    field(:name, :string)
    field(:sync_to_icloud, :boolean, default: true)
    belongs_to(:collection, Manifold.Data.Schema.DAVCollection)
    has_many(:events, Manifold.Data.Schema.CalendarEvent)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(calendar, attrs) do
    calendar
    |> cast(attrs, [:account_id, :collection_id, :name, :sync_to_icloud])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :sync_to_icloud])
    |> validate_length(:name, max: 512)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:collection_id)
    |> unique_constraint(:collection_id)
  end
end
