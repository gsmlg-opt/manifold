defmodule Manifold.Data.Schema.CalendarEvent do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "calendar_events" do
    belongs_to(:calendar, Manifold.Data.Schema.Calendar)
    belongs_to(:resource, Manifold.Data.Schema.DAVResource)
    field(:local_revision, :integer, default: 0)
    field(:deleted_at, :utc_datetime_usec)
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
        :calendar_id,
        :resource_id,
        :local_revision,
        :deleted_at,
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
    |> foreign_key_constraint(:calendar_id)
    |> foreign_key_constraint(:resource_id)
    |> unique_constraint([:collection_id, :resource_href, :uid, :recurrence_id],
      error_key: :resource_href,
      name: :calendar_events_resource_identity_index
    )
    |> check_constraint(:resource_href, name: :calendar_events_href_present)
    |> check_constraint(:uid, name: :calendar_events_uid_present)
  end

  def local_changeset(event, attrs) do
    event
    |> cast(
      attrs,
      [
        :calendar_id,
        :summary,
        :description,
        :location,
        :starts_at,
        :ends_at,
        :timezone,
        :all_day
      ],
      empty_values: []
    )
    |> infer_all_day(attrs)
    |> validate_required([:calendar_id, :starts_at, :all_day])
    |> validate_length(:summary, max: 512)
    |> validate_length(:description, max: 10_000)
    |> validate_length(:location, max: 4096)
    |> validate_length(:timezone, max: 255)
    |> validate_format(:timezone, ~r/\A[^\x00-\x20;:"\\]+\z/,
      message: "must be a valid time zone identifier"
    )
    |> validate_change(:starts_at, &validate_time/2)
    |> validate_change(:ends_at, &validate_time/2)
    |> validate_interval()
    |> foreign_key_constraint(:calendar_id)
  end

  defp infer_all_day(changeset, attrs) do
    if Map.has_key?(attrs, :all_day) or Map.has_key?(attrs, "all_day") do
      changeset
    else
      case fetch_change(changeset, :starts_at) do
        {:ok, value} when is_binary(value) ->
          put_change(changeset, :all_day, byte_size(value) == 8)

        _ ->
          changeset
      end
    end
  end

  defp validate_time(_field, value) when value in [nil, ""], do: []

  defp validate_time(field, value) do
    if valid_time?(value), do: [], else: [{field, "must be a valid iCalendar date or date-time"}]
  end

  defp valid_time?(value) do
    case Regex.run(~r/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?$/, value) do
      [_, year, month, day] ->
        valid_date?(year, month, day)

      [_, year, month, day, hour, minute, second] ->
        valid_date?(year, month, day) and
          match?(
            {:ok, _},
            Time.new(
              String.to_integer(hour),
              String.to_integer(minute),
              String.to_integer(second)
            )
          )

      _ ->
        false
    end
  end

  defp valid_date?(year, month, day),
    do:
      match?(
        {:ok, _},
        Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day))
      )

  defp validate_interval(changeset) do
    start = get_field(changeset, :starts_at)
    finish = get_field(changeset, :ends_at)
    all_day = get_field(changeset, :all_day)

    cond do
      not is_binary(start) or not valid_time?(start) ->
        changeset

      all_day != (byte_size(start) == 8) ->
        add_error(changeset, :starts_at, "must match the all-day setting")

      finish in [nil, ""] or not valid_time?(finish) ->
        changeset

      byte_size(start) != byte_size(finish) ->
        add_error(changeset, :ends_at, "must use the same date/time format as start")

      finish <= start ->
        add_error(changeset, :ends_at, "must be after start")

      true ->
        changeset
    end
  end
end
