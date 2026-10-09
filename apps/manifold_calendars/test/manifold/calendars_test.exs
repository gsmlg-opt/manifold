defmodule Manifold.CalendarsTest do
  use Manifold.DataCase, async: true

  alias Manifold.Calendars
  alias Manifold.Data.Schema.{CalendarEvent, DAVCollection, ICloudConnection}

  test "lists calendars with source metadata and retains event recurrence exceptions" do
    collection = collection_fixture("calendars", "Personal")
    collection_fixture("contacts", "Address Book")
    master = event_fixture(collection, "")
    exception = event_fixture(collection, "20261017T100000")
    assert [%{id: id, connection: %{apple_id: "ada@example.test"}}] = Calendars.list_calendars()
    assert id == collection.id
    events = Calendars.list_events(collection.id)
    assert MapSet.new(Enum.map(events, & &1.id)) == MapSet.new([master.id, exception.id])

    assert %{
             recurrence_rules: ["FREQ=WEEKLY;BYDAY=SA"],
             excluded_dates: ["20261024T100000"],
             timezone: "Europe/London",
             raw: "original ICS"
           } = Calendars.get_event(master.id)

    assert Calendars.get_event(exception.id).recurrence_id == "20261017T100000"
    assert Ecto.assoc_loaded?(Calendars.get_event(master.id).collection.connection)
    assert Calendars.get_event(master.id).collection.connection.password_ciphertext == nil
    assert hd(Calendars.list_calendars()).connection.password_ciphertext == nil
  end

  test "calendar records preserve all-day and floating wall times without recurrence expansion" do
    collection = collection_fixture("calendars", "Personal")

    event =
      event_fixture(collection, "", %{
        starts_at: "20261010",
        ends_at: "20261011",
        all_day: true,
        timezone: nil,
        recurrence_rules: [],
        excluded_dates: []
      })

    assert [%{id: id, all_day: true, starts_at: "20261010", ends_at: "20261011", timezone: nil}] =
             Calendars.list_events(collection.id)

    assert id == event.id
  end

  test "event identity includes collection, resource, UID and recurrence ID" do
    collection = collection_fixture("calendars", "Personal")
    event_fixture(collection, "")

    assert {:error, duplicate} =
             struct(CalendarEvent)
             |> CalendarEvent.changeset(event_attrs(collection, ""))
             |> Repo.insert()

    assert duplicate.errors[:resource_href]
    second = collection_fixture("calendars", "Work")
    other = event_fixture(second, "")
    assert [%{id: id}] = Calendars.list_events(second.id)
    assert id == other.id
  end

  test "event lists order deterministically and paginate actual records" do
    collection = collection_fixture("calendars", "Personal")
    later = event_fixture(collection, "late", %{starts_at: "20261017T100000"})
    earlier = event_fixture(collection, "early", %{starts_at: "20261010T100000"})
    assert Enum.map(Calendars.list_events(collection.id), & &1.id) == [earlier.id, later.id]
    assert [%{id: id}] = Calendars.list_events(collection.id, limit: 1, offset: 1)
    assert id == later.id
  end

  test "malformed and missing IDs yield empty results" do
    for id <- ["bad-uuid", "", nil, Ecto.UUID.generate()] do
      assert Calendars.get_event(id) == nil
      assert Calendars.list_events(id) == []
    end
  end

  test "deleting a connection cascades only its calendars and events" do
    first = collection_fixture("calendars", "Personal")
    second = collection_fixture("calendars", "Work")
    one = event_fixture(first, "")
    two = event_fixture(second, "")
    Repo.delete!(Repo.get!(ICloudConnection, first.connection_id))
    assert Calendars.get_event(one.id) == nil
    assert Calendars.get_event(two.id).id == two.id
    assert Enum.map(Calendars.list_calendars(), & &1.id) == [second.id]
  end

  defp collection_fixture(kind, name) do
    connection =
      struct(ICloudConnection)
      |> ICloudConnection.changeset(%{
        apple_id: "ada@example.test",
        password_ciphertext: <<1, 2, 3>>
      })
      |> Repo.insert!()

    struct(DAVCollection)
    |> DAVCollection.changeset(%{
      connection_id: connection.id,
      kind: kind,
      href: "/#{name}/",
      name: name
    })
    |> Repo.insert!()
  end

  defp event_attrs(collection, recurrence_id) do
    %{
      collection_id: collection.id,
      resource_href: "/weekly.ics",
      uid: "weekly",
      recurrence_id: recurrence_id,
      summary: "Weekly meeting",
      starts_at: "20261010T100000",
      ends_at: "20261010T110000",
      timezone: "Europe/London",
      recurrence_rules: ["FREQ=WEEKLY;BYDAY=SA"],
      excluded_dates: ["20261024T100000"],
      raw: "original ICS"
    }
  end

  defp event_fixture(collection, recurrence_id, attrs \\ %{}) do
    struct(CalendarEvent)
    |> CalendarEvent.changeset(Map.merge(event_attrs(collection, recurrence_id), attrs))
    |> Repo.insert!()
  end
end
