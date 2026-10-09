defmodule Manifold.Data.Schema.CalendarEvent do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "calendar_events" do
    field(:resource_href, :string)
    field(:uid, :string)
    field(:recurrence_id, :string, default: "")
    field(:etag, :string)
    field(:raw, :string)
    field(:summary, :string)
    field(:description, :string)
    field(:location, :string)
    field(:starts_at, :string)
    field(:ends_at, :string)
    field(:timezone, :string)
    field(:all_day, :boolean, default: false)
    field(:recurrence_rules, {:array, :string}, default: [])
    field(:excluded_dates, {:array, :string}, default: [])
    belongs_to(:collection, Manifold.Data.Schema.DAVCollection)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(
      attrs,
      [
        :collection_id,
        :resource_href,
        :uid,
        :recurrence_id,
        :etag,
        :raw,
        :summary,
        :description,
        :location,
        :starts_at,
        :ends_at,
        :timezone,
        :all_day,
        :recurrence_rules,
        :excluded_dates
      ],
      empty_values: []
    )
    |> validate_required([:collection_id, :resource_href, :uid, :starts_at])
    |> foreign_key_constraint(:collection_id)
    |> unique_constraint([:collection_id, :resource_href, :uid, :recurrence_id],
      error_key: :resource_href,
      name: :calendar_events_resource_identity_index
    )
    |> check_constraint(:resource_href, name: :calendar_events_href_present)
    |> check_constraint(:uid, name: :calendar_events_uid_present)
  end
end
