defmodule Manifold.CalendarsTest do
  use Manifold.DataCase, async: true

  alias Manifold.Calendars

  alias Manifold.Data.Schema.{
    Calendar,
    CalendarEvent,
    DAVCollection,
    DAVResource,
    ICloudConnection
  }

  test "lists calendars with source metadata and retains event recurrence exceptions" do
    collection = collection_fixture("calendars", "Personal")
    collection_fixture("contacts", "Address Book")
    master = event_fixture(collection, "")
    exception = event_fixture(collection, "20261017T100000")

    assert [%{collection_id: id, collection: %{connection: %{apple_id: "ada@example.test"}}}] =
             Calendars.list_calendars()

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
    assert hd(Calendars.list_calendars()).collection.connection.password_ciphertext == nil
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

  test "deleting a connection retains local calendars and imported events" do
    first = collection_fixture("calendars", "Personal")
    second = collection_fixture("calendars", "Work")
    one = event_fixture(first, "")
    two = event_fixture(second, "")
    Repo.delete!(Repo.get!(ICloudConnection, first.connection_id))
    assert Calendars.get_event(one.id).collection_id == nil
    assert Calendars.get_event(one.id).resource_href == "/weekly.ics"
    assert Calendars.get_event(two.id).id == two.id
    assert Enum.any?(Calendars.list_calendars(), &(&1.collection_id == second.id))
    assert Enum.any?(Calendars.list_calendars(), &is_nil(&1.collection_id))
  end

  test "unmapped calendars support offline CRUD and preserve date/floating/UTC semantics" do
    assert {:ok, calendar} = Calendars.create_calendar(%{name: "Local calendar"})
    assert calendar.sync_to_icloud
    assert calendar.account_id == nil

    assert {:ok, event} =
             Calendars.create_event(%{
               calendar_id: calendar.id,
               summary: "Birthday",
               starts_at: "20261010",
               ends_at: "20261011",
               all_day: true
             })

    assert event.resource_id == nil
    assert event.local_revision == 1
    assert event.uid

    assert {:ok, updated} =
             Calendars.update_event(event.id, %{
               summary: "Birthday lunch",
               starts_at: "20261010T120000",
               ends_at: "20261010T130000",
               all_day: false,
               timezone: nil
             })

    assert updated.local_revision == 2
    assert updated.starts_at == "20261010T120000"
    assert updated.timezone == nil

    assert {:ok, _} =
             Calendars.update_event(event.id, %{
               starts_at: "20261010T120000Z",
               ends_at: "20261010T130000Z",
               timezone: "UTC"
             })

    assert Calendars.get_event(event.id).timezone == "UTC"
    assert {:error, :not_empty} = Calendars.delete_calendar(calendar.id)
    assert {:ok, _} = Calendars.delete_event(event.id)
    assert Calendars.get_event(event.id) == nil
    assert {:ok, _} = Calendars.update_calendar(calendar.id, %{name: "Renamed"})
    assert Calendars.get_calendar(calendar.id).name == "Renamed"
    assert {:ok, _} = Calendars.delete_calendar(calendar.id)
    assert Calendars.get_calendar(calendar.id) == nil
  end

  test "mapped event saves are durable while the provider is offline and coalesce revisions" do
    {account, _, collection} = target_fixture()
    calendar = Repo.get_by!(Calendar, collection_id: collection.id)
    assert calendar.account_id == account.id

    assert {:ok, event} =
             Calendars.create_event(%{
               calendar_id: calendar.id,
               summary: "Draft",
               starts_at: "20261010T100000",
               timezone: "Europe/London"
             })

    first = Repo.get!(DAVResource, event.resource_id)
    assert first.status == "pending"
    assert first.desired_revision == 1
    assert first.acknowledged_revision == 0
    assert first.base_raw == nil
    assert {:ok, _} = Calendars.update_event(event.id, %{location: "Local edit"})
    assert Repo.get!(DAVResource, first.id).desired_revision == 2
    assert Repo.get!(DAVResource, first.id).href == first.href
    assert {:ok, _} = Calendars.update_calendar(calendar.id, %{sync_to_icloud: false})
    assert Repo.get!(DAVResource, first.id).status == "paused"
    assert {:ok, _} = Calendars.update_event(event.id, %{summary: "Paused draft"})
    assert Repo.get!(DAVResource, first.id).status == "paused"
    assert {:ok, _} = Calendars.update_calendar(calendar.id, %{sync_to_icloud: true})
    assert Repo.get!(DAVResource, first.id).status == "pending"
  end

  test "deleting an exception stages PUT while series and sibling components remain" do
    {account, _, collection} = target_fixture()

    collection =
      collection
      |> DAVCollection.changeset(%{can_update: true, can_delete: false})
      |> Repo.update!()

    Repo.get_by!(Calendar, collection_id: collection.id)
    |> Calendar.changeset(%{account_id: account.id})
    |> Repo.update!()

    master = event_fixture(collection, "")
    exception = event_fixture(collection, "20261017T100000")
    sibling = event_fixture(collection, "", %{uid: "other-series"})

    resource =
      struct(DAVResource)
      |> DAVResource.changeset(%{
        kind: "calendars",
        account_id: account.id,
        connection_id: collection.connection_id,
        collection_id: collection.id,
        href: "/weekly.ics",
        uid: "weekly",
        base_raw: "complete original ICS",
        etag: "\"base\"",
        status: "synced"
      })
      |> Repo.insert!()

    for event <- [master, exception, sibling],
        do: event |> change(resource_id: resource.id) |> Repo.update!()

    assert {:ok, _} = Calendars.delete_event(exception.id)
    assert Calendars.get_event(exception.id) == nil
    assert Calendars.get_event(master.id)
    assert Repo.get!(DAVResource, resource.id).operation == "upsert"
    assert Repo.get!(DAVResource, resource.id).base_raw == "complete original ICS"
    assert {:ok, _} = Calendars.delete_event(master.id, whole_series: true)
    assert Calendars.get_event(sibling.id)
    assert Repo.get!(DAVResource, resource.id).operation == "upsert"
    assert {:error, :read_only} = Calendars.delete_event(sibling.id, whole_series: true)
    collection |> DAVCollection.changeset(%{can_delete: true}) |> Repo.update!()
    assert {:ok, _} = Calendars.delete_event(sibling.id, whole_series: true)
    assert Repo.get!(DAVResource, resource.id).operation == "delete"
    assert Repo.get!(DAVResource, resource.id).status == "pending"
    assert Repo.get!(CalendarEvent, exception.id).deleted_at
  end

  test "readonly sources reject remote edits and allow explicit local copies" do
    collection = collection_fixture("calendars", "Read only")
    remote = event_fixture(collection, "")
    assert {:error, :read_only} = Calendars.update_event(remote.id, %{summary: "Unsafe"})
    assert {:error, :read_only} = Calendars.delete_event(remote.id)
    assert {:ok, local} = Calendars.create_calendar(%{name: "Local copies"})
    assert {:ok, copy} = Calendars.copy_event(remote.id, %{calendar_id: local.id})
    assert copy.id != remote.id
    assert copy.uid != remote.uid
    assert copy.resource_id == nil
    assert Calendars.get_event(remote.id).summary == "Weekly meeting"
  end

  test "local time validation rejects impossible dates and non-increasing intervals" do
    assert {:ok, calendar} = Calendars.create_calendar(%{name: "Local"})

    for start <- ["20260230", "20261010T250000", "20261301"] do
      assert {:error, _} = Calendars.create_event(%{calendar_id: calendar.id, starts_at: start})
    end

    assert {:error, _} =
             Calendars.create_event(%{
               calendar_id: calendar.id,
               starts_at: "20261010T120000Z",
               ends_at: "20261010T100000Z"
             })

    assert {:error, _} =
             Calendars.create_event(%{
               calendar_id: calendar.id,
               starts_at: "20261010",
               all_day: false
             })

    assert {:error, _} =
             Calendars.create_event(%{
               calendar_id: calendar.id,
               starts_at: "20261010T120000",
               timezone: "Europe/London\r\nX-INVALID:yes"
             })

    assert {:ok, %{all_day: true}} =
             Calendars.create_event(%{
               calendar_id: calendar.id,
               starts_at: "20261010",
               ends_at: "20261011"
             })
  end

  test "validates local calendars, event times and cross-account mapping without writing intents" do
    assert {:error, _} = Calendars.create_calendar(%{name: " "})
    assert {:ok, local} = Calendars.create_calendar(%{name: "Local"})
    assert {:error, _} = Calendars.create_event(%{calendar_id: local.id, starts_at: "not-a-date"})
    assert {:error, _} = Calendars.create_event(%{calendar_id: local.id})
    {account, _, collection} = target_fixture()
    other = account_fixture()

    assert {:error, :invalid_destination} =
             Calendars.create_calendar(%{
               name: "Wrong account",
               account_id: other.id,
               collection_id: collection.id
             })

    assert {:ok, mapped} =
             Calendars.update_calendar(Repo.get_by!(Calendar, collection_id: collection.id).id, %{
               account_id: account.id
             })

    assert {:ok, event} = Calendars.create_event(%{calendar_id: mapped.id, starts_at: "20261010"})

    assert {:error, :local_copy_required} =
             Calendars.update_event(event.id, %{calendar_id: local.id})

    assert {:error, :local_copy_required} =
             Calendars.update_calendar(mapped.id, %{collection_id: nil})

    assert Repo.get!(DAVResource, event.resource_id).desired_revision == 1
  end

  defp account_fixture do
    domain =
      struct(Manifold.Accounts.Schema.Domain)
      |> Manifold.Accounts.Schema.Domain.changeset(%{
        name: "c#{System.unique_integer([:positive])}.example.test"
      })
      |> Repo.insert!()

    struct(Manifold.Accounts.Schema.Account)
    |> Manifold.Accounts.Schema.Account.changeset(%{domain_id: domain.id, local_part: "ada"})
    |> Repo.insert!()
  end

  test "explicit destination merge preserves imports and enrolls only the local source events" do
    {account, _, collection} = target_fixture()
    destination = Repo.get_by!(Calendar, collection_id: collection.id)
    {imported, baseline} = bound_import_fixture(collection)

    assert {:ok, source} =
             Calendars.create_calendar(%{name: "My local calendar", account_id: account.id})

    assert {:ok, local} =
             Calendars.create_event(%{
               calendar_id: source.id,
               starts_at: "20261011",
               summary: "Local draft"
             })

    assert is_nil(local.resource_id)

    assert {:error, :merge_required} =
             Calendars.update_calendar(source.id, %{collection_id: collection.id})

    assert Calendars.get_event(imported.id).calendar_id == destination.id

    assert {:ok, merged} =
             Calendars.update_calendar(source.id, %{
               collection_id: collection.id,
               merge_destination: true
             })

    assert merged.id == source.id
    assert Calendars.get_calendar(destination.id) == nil
    preserved = Calendars.get_event(imported.id)
    assert preserved.calendar_id == source.id

    for field <- [:id, :resource_id, :collection_id, :raw, :local_revision, :uid, :recurrence_id],
        do: assert(Map.get(preserved, field) == Map.get(imported, field))

    assert Repo.get!(DAVResource, baseline.id) == baseline
    enrolled = Calendars.get_event(local.id)
    assert enrolled.id == local.id
    assert enrolled.resource.collection_id == collection.id
    assert enrolled.resource.desired_revision == 1
    assert enrolled.resource.status == "pending"

    assert {:error, :local_copy_required} =
             Calendars.update_calendar(source.id, %{
               collection_id: nil,
               merge_destination: true
             })
  end

  test "new calendar destination adoption requires explicit choice and preserves imported baselines" do
    {account, _, collection} = target_fixture()
    destination = Repo.get_by!(Calendar, collection_id: collection.id)
    {imported, baseline} = bound_import_fixture(collection)
    attrs = %{name: "Chosen name", account_id: account.id, collection_id: collection.id}
    assert {:error, :merge_required} = Calendars.create_calendar(attrs)
    assert {:ok, created} = Calendars.create_calendar(Map.put(attrs, :merge_destination, true))
    assert created.id != destination.id
    assert Calendars.get_calendar(destination.id) == nil
    assert Calendars.get_event(imported.id).calendar_id == created.id
    assert Repo.get!(DAVResource, baseline.id) == baseline
  end

  test "destination adoption changes only operational state when calendar preferences differ" do
    for {previous, selected, status, expected} <- [
          {true, false, "synced", "paused"},
          {false, true, "paused", "synced"},
          {false, true, "conflict", "conflict"}
        ] do
      {account, _, collection} = target_fixture()
      destination = Repo.get_by!(Calendar, collection_id: collection.id)
      destination |> change(sync_to_icloud: previous) |> Repo.update!()
      {imported, baseline} = bound_import_fixture(collection)
      baseline = baseline |> change(status: status) |> Repo.update!()

      assert {:ok, source} =
               Calendars.create_calendar(%{
                 name: "Preference merge",
                 account_id: account.id,
                 sync_to_icloud: selected
               })

      assert {:ok, _} =
               Calendars.update_calendar(source.id, %{
                 collection_id: collection.id,
                 merge_destination: true
               })

      updated = Repo.get!(DAVResource, baseline.id)
      assert updated.status == expected
      assert updated.desired_revision == baseline.desired_revision
      assert updated.acknowledged_revision == baseline.acknowledged_revision
      assert updated.base_raw == baseline.base_raw
      assert Calendars.get_event(imported.id).calendar_id == source.id
    end
  end

  defp bound_import_fixture(collection) do
    calendar = Repo.get_by!(Calendar, collection_id: collection.id)

    resource =
      Repo.insert!(%DAVResource{
        kind: "calendars",
        account_id: calendar.account_id,
        connection_id: collection.connection_id,
        collection_id: collection.id,
        href: "/weekly.ics",
        uid: "weekly",
        base_raw: "original ICS",
        etag: "\"baseline\"",
        status: "synced"
      })

    imported = event_fixture(collection, "") |> change(resource_id: resource.id) |> Repo.update!()
    {imported, resource}
  end

  test "pending, dispatched and conflict tombstones retain their local calendar" do
    {_, _, collection} = target_fixture()
    calendar = Repo.get_by!(Calendar, collection_id: collection.id)

    assert {:ok, event} =
             Calendars.create_event(%{calendar_id: calendar.id, starts_at: "20261010"})

    resource = Repo.get!(DAVResource, event.resource_id)
    resource |> change(base_raw: "shared base", etag: "\"base\"") |> Repo.update!()
    assert {:ok, _} = Calendars.delete_event(event.id)
    assert Calendars.list_events(calendar.id) == []

    for attrs <- [
          %{status: "pending", desired_revision: 2, acknowledged_revision: 1, sent_revision: nil},
          %{status: "uncertain", desired_revision: 2, acknowledged_revision: 2, sent_revision: 2},
          %{status: "conflict", desired_revision: 2, acknowledged_revision: 2, sent_revision: nil}
        ] do
      Repo.get!(DAVResource, resource.id) |> change(attrs) |> Repo.update!()
      assert {:error, :sync_pending} = Calendars.delete_calendar(calendar.id)
      assert Repo.get!(CalendarEvent, event.id).calendar_id == calendar.id
    end

    Repo.get!(DAVResource, resource.id)
    |> change(status: "synced", sent_revision: nil)
    |> Repo.update!()

    assert {:ok, _} = Calendars.delete_calendar(calendar.id)
    assert Repo.get!(CalendarEvent, event.id).resource_id == resource.id
  end

  test "remapping an unbound calendar fences its previous Account's purge" do
    previous = account_fixture()
    requested = account_fixture()

    assert {:ok, calendar} =
             Calendars.create_calendar(%{name: "Retained", account_id: previous.id})

    previous |> change(purge_requested_at: DateTime.utc_now()) |> Repo.update!()

    assert {:error, :account_purging} =
             Calendars.update_calendar(calendar.id, %{account_id: requested.id})

    assert Calendars.get_calendar(calendar.id).account_id == previous.id
  end

  defp target_fixture do
    account = account_fixture()
    collection = collection_fixture("calendars", "Writable")

    connection =
      Repo.get!(ICloudConnection, collection.connection_id)
      |> ICloudConnection.changeset(%{account_id: account.id})
      |> Repo.update!()

    collection = collection |> DAVCollection.changeset(%{writable: true}) |> Repo.update!()

    Repo.get_by!(Calendar, collection_id: collection.id)
    |> Calendar.changeset(%{account_id: account.id})
    |> Repo.update!()

    {account, connection, collection}
  end

  defp collection_fixture(kind, name) do
    connection =
      struct(ICloudConnection)
      |> ICloudConnection.changeset(%{
        apple_id: "ada@example.test",
        password_ciphertext: <<1, 2, 3>>
      })
      |> Repo.insert!()

    collection =
      struct(DAVCollection)
      |> DAVCollection.changeset(%{
        connection_id: connection.id,
        kind: kind,
        href: "/#{name}/",
        name: name
      })
      |> Repo.insert!()

    if kind == "calendars" do
      struct(Calendar)
      |> Calendar.changeset(%{collection_id: collection.id, name: name})
      |> Repo.insert!()
    end

    collection
  end

  defp event_attrs(collection, recurrence_id) do
    %{
      collection_id: collection.id,
      calendar_id: Repo.get_by!(Calendar, collection_id: collection.id).id,
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
