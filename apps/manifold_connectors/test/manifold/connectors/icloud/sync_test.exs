defmodule Manifold.Connectors.ICloud.SyncTest do
  use Manifold.DataCase, async: true
  alias Manifold.Connectors.{ICloud, ICloud.Sync}
  alias Manifold.Data.Schema.{ICloudConnection, Contact, CalendarEvent}

  defmodule FakeClient do
    def discover(_, kind, opts) do
      if Keyword.get(opts, :discovery_failure) == kind,
        do: {:error, :unauthorized},
        else:
          {:ok, [%{href: "https://contacts.icloud.com/#{kind}/", name: kind, sync_token: nil}]}
    end

    def sync_collection(collection, _, opts) do
      if opts[:before_read], do: opts[:before_read].()

      case Keyword.get(opts, String.to_existing_atom(collection.kind)) do
        {:error, reason} -> {:error, reason}
        snapshot when is_map(snapshot) -> {:ok, snapshot}
        _ -> {:ok, %{mode: :full, entries: [], deleted: [], sync_token: nil}}
      end
    end
  end

  defp snapshot(name, version \\ "1") do
    href = "https://contacts.icloud.com/contacts/ada.vcf"

    raw =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ada\r\nFN:#{name}\r\nEMAIL:ada@example.test\r\nEND:VCARD\r\n"

    %{
      mode: :full,
      entries: [%{href: href, etag: version, content: raw}],
      deleted: [],
      sync_token: "token:#{version}"
    }
  end

  defp connection do
    {:ok, connection} =
      ICloud.connect(%{
        apple_id: "apple@example.test",
        app_password: "aaaa-bbbb-cccc-dddd",
        contacts_enabled: true,
        calendars_enabled: false
      })

    connection
  end

  test "initial import, idempotence, changes and complete deletion" do
    c = connection()
    assert :ok = Sync.run(c.id, c.generation, client: FakeClient, contacts: snapshot("Ada"))
    assert [first] = Repo.all(Contact)
    assert first.full_name == "Ada"
    assert :ok = Sync.run(c.id, c.generation, client: FakeClient, contacts: snapshot("Ada"))
    assert [%{id: id}] = Repo.all(Contact)
    assert id == first.id

    assert :ok =
             Sync.run(c.id, c.generation,
               client: FakeClient,
               contacts: snapshot("Ada Updated", "2")
             )

    assert Repo.get!(Contact, first.id).full_name == "Ada Updated"
    assert :ok = Sync.run(c.id, c.generation, client: FakeClient)
    assert Repo.all(Contact) == []
  end

  test "failed or invalid snapshot retains prior records and checkpoint" do
    c = connection()
    :ok = Sync.run(c.id, c.generation, client: FakeClient, contacts: snapshot("Ada"))
    first = hd(Repo.all(Contact))

    assert {:error, _} =
             Sync.run(c.id, c.generation,
               client: FakeClient,
               contacts: {:error, :incomplete_response}
             )

    assert Repo.get(Contact, first.id)
    broken = snapshot("Broken") |> put_in([:entries, Access.at(0), :content], "truncated-card")
    assert {:error, _} = Sync.run(c.id, c.generation, client: FakeClient, contacts: broken)
    assert Repo.get!(Contact, first.id).full_name == "Ada"
    assert Repo.get!(ICloudConnection, c.id).contacts_synced_at
  end

  test "lifecycle replacement and disconnection fence old data and failure commits" do
    c = connection()

    assert {:error, :stale} =
             Sync.run(c.id, c.generation,
               client: FakeClient,
               contacts: snapshot("Old"),
               before_read: fn -> ICloud.set_enabled(c.id, false) end
             )

    assert Repo.all(Contact) == []
    refute Repo.get!(ICloudConnection, c.id).enabled
    {:ok, enabled} = ICloud.set_enabled(c.id, true)
    assert {:error, :stale} = Sync.run(c.id, c.generation, client: FakeClient)

    assert {:error, :stale} =
             Sync.run(c.id, enabled.generation,
               client: FakeClient,
               contacts: snapshot("Old"),
               before_read: fn -> ICloud.disconnect(c.id) end
             )

    assert Repo.get(ICloudConnection, c.id) == nil
    assert Repo.all(Contact) == []
  end

  test "unchanged resources require existing matching records and leases serialize work" do
    c = connection()
    :ok = Sync.run(c.id, c.generation, client: FakeClient, contacts: snapshot("Ada"))
    unchanged = snapshot("Ada") |> put_in([:entries, Access.at(0), :content], nil)
    assert :ok = Sync.run(c.id, c.generation, client: FakeClient, contacts: unchanged)
    mismatch = unchanged |> put_in([:entries, Access.at(0), :etag], "unknown")
    assert {:error, _} = Sync.run(c.id, c.generation, client: FakeClient, contacts: mismatch)
    assert hd(Repo.all(Contact)).full_name == "Ada"

    Repo.update_all(ICloudConnection,
      set: [
        sync_owner: Ecto.UUID.generate(),
        sync_expires_at: DateTime.add(DateTime.utc_now(), 300)
      ]
    )

    assert {:error, :busy} = Sync.run(c.id, c.generation, client: FakeClient)
    assert hd(Repo.all(Contact)).full_name == "Ada"
  end

  test "delta deletions and updates checkpoint only successful resources" do
    c = connection()
    :ok = Sync.run(c.id, c.generation, client: FakeClient, contacts: snapshot("Ada"))

    delta = %{
      mode: :delta,
      entries: [],
      deleted: ["https://contacts.icloud.com/contacts/ada.vcf"],
      sync_token: "deleted"
    }

    assert :ok = Sync.run(c.id, c.generation, client: FakeClient, contacts: delta)
    assert Repo.all(Contact) == []
  end

  test "a later service throttle controls retries and no request bypasses Retry-After" do
    {:ok, c} =
      ICloud.connect(%{
        apple_id: "+8613912345678",
        app_password: "pass",
        contacts_enabled: true,
        calendars_enabled: true
      })

    assert {:error, {:rate_limited, 3600}} =
             Sync.run(c.id, c.generation,
               client: FakeClient,
               contacts: {:error, :incomplete_response},
               calendars: {:error, {:rate_limited, 3600}}
             )

    assert {:error, {:rate_limited, remaining}} =
             Sync.run(c.id, c.generation,
               client: FakeClient,
               before_read: fn -> flunk("no network call while throttled") end
             )

    assert remaining > 3500
    assert {:error, :rate_limited} = ICloud.sync_now(c.id)
  end

  test "calendar success remains visible despite contact authentication failure" do
    {:ok, c} =
      ICloud.connect(%{
        apple_id: "apple@example.test",
        app_password: "pass",
        contacts_enabled: true,
        calendars_enabled: true
      })

    raw =
      "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:meeting\nDTSTART:20261010T120000Z\nSUMMARY:Meeting\nEND:VEVENT\nEND:VCALENDAR\n"

    calendar = %{
      mode: :full,
      entries: [
        %{href: "https://contacts.icloud.com/calendars/event.ics", etag: "1", content: raw}
      ],
      deleted: [],
      sync_token: nil
    }

    assert {:error, _} =
             Sync.run(c.id, c.generation,
               client: FakeClient,
               discovery_failure: "contacts",
               calendars: calendar
             )

    assert [event] = Repo.all(CalendarEvent)
    assert event.summary == "Meeting"
    stored = Repo.get!(ICloudConnection, c.id)
    assert stored.contacts_status == "reconnect_required"
    assert stored.calendars_status == "connected"
  end
end
