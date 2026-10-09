defmodule Manifold.Calendars do
  @moduledoc """
  Read-only calendar resources and event records, without recurrence expansion.

  Start/end values retain the original iCalendar representation. The timezone
  field distinguishes UTC, named TZID and floating local times.
  """

  import Ecto.Query
  alias Manifold.Data.Schema.{CalendarEvent, DAVCollection, ICloudConnection}
  alias Manifold.Repo

  def list_calendars do
    DAVCollection
    |> where([collection], collection.kind == "calendars")
    |> order_by([collection],
      asc: fragment("lower(coalesce(?, ?))", collection.name, collection.href),
      asc: collection.id
    )
    |> Repo.all()
    |> Repo.preload(connection: public_connections())
  end

  def list_events(collection_id, opts \\ []) do
    with {:ok, uuid} <- Ecto.UUID.cast(collection_id) do
      limit = bounded_integer(Keyword.get(opts, :limit), 100, 1, 500)
      offset = bounded_integer(Keyword.get(opts, :offset), 0, 0, 1_000_000)

      CalendarEvent
      |> where([event], event.collection_id == ^uuid)
      |> order_by([event],
        asc: event.starts_at,
        asc: event.uid,
        asc: event.recurrence_id,
        asc: event.id
      )
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()
      |> Repo.preload(collection: [connection: public_connections()])
    else
      _ -> []
    end
  end

  def get_event(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %CalendarEvent{} = event <- Repo.get(CalendarEvent, uuid) do
      Repo.preload(event, collection: [connection: public_connections()])
    else
      _ -> nil
    end
  end

  defp public_connections do
    from(connection in ICloudConnection,
      select:
        struct(connection, [
          :id,
          :apple_id,
          :enabled,
          :contacts_enabled,
          :calendars_enabled,
          :contacts_status,
          :contacts_synced_at,
          :calendars_status,
          :calendars_synced_at
        ])
    )
  end

  defp bounded_integer(value, _default, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp bounded_integer(_, default, _, _), do: default
end
