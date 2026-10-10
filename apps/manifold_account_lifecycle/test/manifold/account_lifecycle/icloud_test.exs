defmodule Manifold.AccountLifecycle.ICloudTest do
  use Manifold.DataCase, async: false
  alias Manifold.{Accounts, Contacts, Calendars, AccountLifecycle, Connectors}
  alias Manifold.Connectors.ICloud

  alias Manifold.Data.Schema.{
    Contact,
    Calendar,
    CalendarEvent,
    DAVCollection,
    DAVResource,
    ICloudConnection
  }

  setup do
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})

    {:ok, account} =
      Accounts.create_account(%{address: "icloud-#{Ecto.UUID.generate()}@example.test"})

    {:ok, other} =
      Accounts.create_account(%{address: "other-#{Ecto.UUID.generate()}@example.test"})

    {:ok, c} =
      ICloud.connect(%{
        account_id: account.id,
        apple_id: "test@icloud.com",
        app_password: "test-password"
      })

    %{account: account, other: other, connection: c}
  end

  test "Account disable invalidates cloud leases and retains local data", %{
    account: account,
    connection: c
  } do
    {:ok, contact} = Contacts.create_contact(%{account_id: account.id, full_name: "Retained"})
    {:ok, _} = AccountLifecycle.disable_account(account.id)
    updated = Repo.get!(ICloudConnection, c.id)
    refute updated.enabled
    assert updated.generation == c.generation + 1
    assert Contacts.get_contact(contact.id).full_name == "Retained"
    assert Enum.all?(Repo.all(Oban.Job), &(&1.state == "cancelled"))
  end

  test "durable Account purge removes its local cloud data and preserves other Accounts", %{
    account: account,
    other: other,
    connection: c
  } do
    {:ok, mine} = Contacts.create_contact(%{account_id: account.id, full_name: "Mine"})
    {:ok, retained} = Contacts.create_contact(%{account_id: other.id, full_name: "Other"})
    {:ok, unassigned} = Contacts.create_contact(%{full_name: "Unassigned"})
    {:ok, calendar} = Calendars.create_calendar(%{account_id: account.id, name: "Local calendar"})

    {:ok, event} =
      Calendars.create_event(%{calendar_id: calendar.id, starts_at: "20261010T120000Z"})

    {:ok, purge} =
      AccountLifecycle.request_deletion(account.id, Accounts.account_address(account))

    job = %Oban.Job{args: %{"purge_id" => purge.id}}

    outcome =
      Enum.reduce_while(1..100, nil, fn _, _ ->
        case Manifold.AccountLifecycle.Purge.run(purge.id, job) do
          :ok -> {:halt, :ok}
          {:snooze, _} -> {:cont, :working}
          failure -> {:halt, failure}
        end
      end)

    assert outcome == :ok
    assert Accounts.get_account(account.id) == nil
    assert Repo.get(ICloudConnection, c.id) == nil
    assert Repo.get(Contact, mine.id) == nil
    assert Repo.get(Calendar, calendar.id) == nil
    assert Repo.get(CalendarEvent, event.id) == nil
    assert Contacts.get_contact(retained.id)
    assert Contacts.get_contact(unassigned.id)
    assert Repo.aggregate(DAVResource, :count) == 0
    refute Connectors.account_data_remaining?(account.id)
  end

  test "Account purge removes retained event tombstones after their local calendar is deleted", %{
    account: account,
    other: other,
    connection: connection
  } do
    collection =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "calendars",
        name: "Retained source",
        href: "https://caldav.icloud.com/calendar/",
        writable: true
      })

    {:ok, calendar} =
      Calendars.create_calendar(%{
        account_id: account.id,
        collection_id: collection.id,
        name: "Retained tombstones"
      })

    resource =
      Repo.insert!(%DAVResource{
        account_id: account.id,
        connection_id: connection.id,
        collection_id: collection.id,
        kind: "calendars",
        href: "https://caldav.icloud.com/calendar/deleted.ics",
        uid: "deleted",
        desired_revision: 1,
        acknowledged_revision: 1,
        status: "synced",
        operation: "delete"
      })

    bound =
      Repo.insert!(%CalendarEvent{
        calendar_id: calendar.id,
        collection_id: collection.id,
        resource_id: resource.id,
        resource_href: resource.href,
        uid: "deleted",
        starts_at: "20261010",
        raw: "Retained private event document",
        deleted_at: DateTime.utc_now()
      })

    legacy =
      Repo.insert!(%CalendarEvent{
        calendar_id: calendar.id,
        collection_id: collection.id,
        resource_href: "https://caldav.icloud.com/calendar/legacy.ics",
        uid: "legacy",
        starts_at: "20261010",
        raw: "Retained private legacy document",
        deleted_at: DateTime.utc_now()
      })

    assert {:ok, _} = Calendars.delete_calendar(calendar.id)
    assert Repo.get!(CalendarEvent, bound.id).calendar_id == nil
    assert Repo.get!(CalendarEvent, legacy.id).calendar_id == nil

    other_resource =
      Repo.insert!(%DAVResource{
        account_id: other.id,
        kind: "calendars",
        href: "/other-deleted.ics",
        uid: "other",
        status: "synced"
      })

    other_event =
      Repo.insert!(%CalendarEvent{
        resource_id: other_resource.id,
        resource_href: "/other-deleted.ics",
        uid: "other",
        starts_at: "20261010",
        raw: "Another Account's retained document",
        deleted_at: DateTime.utc_now()
      })

    {:ok, purge} =
      AccountLifecycle.request_deletion(account.id, Accounts.account_address(account))

    job = %Oban.Job{args: %{"purge_id" => purge.id}}

    outcome =
      Enum.reduce_while(1..100, nil, fn _, _ ->
        case Manifold.AccountLifecycle.Purge.run(purge.id, job) do
          :ok -> {:halt, :ok}
          {:snooze, _} -> {:cont, :working}
          failure -> {:halt, failure}
        end
      end)

    assert outcome == :ok
    assert Accounts.get_account(account.id) == nil
    assert Repo.get(CalendarEvent, bound.id) == nil
    assert Repo.get(CalendarEvent, legacy.id) == nil
    assert Repo.get(DAVResource, resource.id) == nil
    assert Repo.get!(CalendarEvent, other_event.id).raw == other_event.raw
    assert Repo.get!(DAVResource, other_resource.id).account_id == other.id
    refute Connectors.account_data_remaining?(account.id)
  end
end
