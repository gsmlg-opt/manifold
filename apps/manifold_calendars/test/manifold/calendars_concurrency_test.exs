defmodule Manifold.CalendarsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Manifold.{Calendars, Repo}

  alias Manifold.Data.Schema.{
    Calendar,
    CalendarEvent,
    DAVCollection,
    DAVResource,
    ICloudConnection
  }

  test "a remap cannot detach an event bound while it waits for the Account lock" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])

    domain =
      Repo.insert!(%Manifold.Accounts.Schema.Domain{
        name: "calendar-race-#{suffix}.example.test",
        normalized_domain: "calendar-race-#{suffix}.example.test"
      })

    account =
      Repo.insert!(%Manifold.Accounts.Schema.Account{
        domain_id: domain.id,
        local_part: "local",
        canonical_local_part: "local"
      })

    connection =
      Repo.insert!(%ICloudConnection{
        account_id: account.id,
        apple_id: "calendar-race-#{suffix}@example.test",
        password_ciphertext: <<1, 2, 3>>
      })

    original =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "calendars",
        href: "/original/",
        writable: true
      })

    requested =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "calendars",
        href: "/requested/",
        writable: true
      })

    {:ok, calendar} =
      Calendars.create_calendar(%{
        name: "Race",
        account_id: account.id,
        collection_id: original.id
      })

    parent = self()
    barrier = make_ref()

    remapper =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:backend_pid, barrier, backend_pid})

          receive do
            :start -> Calendars.update_calendar(calendar.id, %{collection_id: requested.id})
          after
            5_000 -> raise "missing start barrier"
          end
        after
          Sandbox.checkin(Repo)
        end
      end)

    handler = {__MODULE__, barrier}
    query_event = Keyword.fetch!(Repo.config(), :telemetry_prefix) ++ [:query]

    :ok =
      :telemetry.attach(
        handler,
        query_event,
        fn _, _, metadata, _ ->
          if self() == remapper.pid and is_nil(Process.get(barrier)) and
               String.starts_with?(metadata.query, "SELECT") and
               String.contains?(metadata.query, "FROM \"calendars\"") do
            Process.put(barrier, true)
            send(parent, {:snapshot_read, barrier})

            receive do
              {:continue, ^barrier} -> :ok
            after
              5_000 -> raise "missing calendar snapshot barrier"
            end
          end
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      send(remapper.pid, {:continue, barrier})
      if Process.alive?(remapper.pid), do: Process.exit(remapper.pid, :kill)
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        Repo.delete_all(from e in CalendarEvent, where: e.calendar_id == ^calendar.id)

        Repo.delete_all(
          from j in Oban.Job,
            where: fragment("?->>'connection_id'", j.args) == ^connection.id
        )

        Repo.delete_all(from r in DAVResource, where: r.connection_id == ^connection.id)
        Repo.delete_all(from c in Calendar, where: c.id == ^calendar.id)
        Repo.delete!(Repo.get!(ICloudConnection, connection.id))
        Repo.delete!(Repo.get!(Manifold.Accounts.Schema.Account, account.id))
        Repo.delete!(Repo.get!(Manifold.Accounts.Schema.Domain, domain.id))
      after
        Sandbox.checkin(Repo)
      end
    end)

    assert_receive {:backend_pid, ^barrier, backend_pid}, 5_000

    assert {:ok, event} =
             Repo.transaction(fn ->
               Repo.one!(
                 from a in Manifold.Accounts.Schema.Account,
                   where: a.id == ^account.id,
                   lock: "FOR UPDATE"
               )

               send(remapper.pid, :start)
               assert_receive {:snapshot_read, ^barrier}, 5_000
               send(remapper.pid, {:continue, barrier})
               await_account_lock(backend_pid, System.monotonic_time(:millisecond) + 5_000)

               {:ok, event} =
                 Calendars.create_event(%{
                   calendar_id: calendar.id,
                   starts_at: "20261010",
                   summary: "Concurrent create"
                 })

               event
             end)

    assert {:error, :local_copy_required} = Task.await(remapper, 5_000)
    assert Calendars.get_calendar(calendar.id).collection_id == original.id
    assert Calendars.get_event(event.id).collection_id == original.id
    resource = Repo.get!(DAVResource, event.resource_id)
    assert resource.collection_id == original.id
    assert resource.account_id == account.id
  end

  defp await_account_lock(backend_pid, deadline) do
    Repo.query!("SELECT pg_stat_clear_snapshot()")

    result =
      Repo.query!(
        "SELECT wait_event_type, query FROM pg_stat_activity WHERE pid = $1",
        [backend_pid]
      )

    case result.rows do
      [["Lock", query]] ->
        assert String.contains?(query, "mailboxes")

      _ ->
        assert System.monotonic_time(:millisecond) < deadline,
               "remapper did not wait for its Account row lock"

        Process.sleep(10)
        await_account_lock(backend_pid, deadline)
    end
  end
end
