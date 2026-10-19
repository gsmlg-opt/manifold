defmodule Manifold.Connectors.ICloud.BidirectionalTest do
  use Manifold.DataCase, async: true
  alias Manifold.Connectors.{ICloud, ICloud.Sync}
  alias Manifold.Connectors.ICloud.Outbound
  alias Manifold.Data.Schema.{Contact, DAVResource, ICloudConnection}
  alias Manifold.Contacts

  defmodule Server do
    def discover(_, "contacts", opts) do
      if opts[:unauthorized_contacts] do
        {:error, :unauthorized}
      else
        {:ok,
         [
           %{
             href: "https://contacts.icloud.com/book/",
             name: "Contacts",
             can_create: true,
             can_update: true,
             can_delete: true,
             writable: true
           }
         ]}
      end
    end

    def discover(_, "calendars", _),
      do:
        {:ok,
         [
           %{
             href: "https://contacts.icloud.com/calendar/",
             name: "Calendar",
             can_create: true,
             can_update: true,
             can_delete: true,
             writable: true
           }
         ]}

    def sync_collection(collection, _, _) do
      entries =
        for {href, %{content: content, etag: etag}} <- Process.get(:remote, %{}),
            String.starts_with?(href, collection.href),
            do: %{href: href, content: content, etag: etag}

      {:ok, %{mode: :full, entries: entries, deleted: [], sync_token: nil}}
    end

    def get_resource(href, _, _), do: {:ok, Map.get(Process.get(:remote, %{}), href, :missing)}

    def put_resource(href, _, _, body, condition, opts) do
      Process.put(:writes, [{:put, href, condition, body} | Process.get(:writes, [])])
      existing = Map.get(Process.get(:remote, %{}), href)

      cond do
        opts[:write_error] ->
          {:error, opts[:write_error]}

        opts[:fail_before_write] ->
          {:error, :outcome_unknown}

        condition == :create and existing != nil ->
          {:error, :conflict}

        is_binary(condition) and (is_nil(existing) or existing.etag != condition) ->
          {:error, :conflict}

        true ->
          if opts[:on_write], do: opts[:on_write].()
          etag = "\"#{System.unique_integer([:positive])}\""

          Process.put(
            :remote,
            Map.put(Process.get(:remote, %{}), href, %{content: body, etag: etag})
          )

          if opts[:lose_response], do: {:error, :outcome_unknown}, else: {:ok, %{etag: etag}}
      end
    end

    def delete_resource(href, _, etag, opts) do
      Process.put(:writes, [{:delete, href, etag} | Process.get(:writes, [])])
      existing = Map.get(Process.get(:remote, %{}), href)

      if existing && existing.etag != etag do
        {:error, :conflict}
      else
        Process.put(:remote, Map.delete(Process.get(:remote, %{}), href))
        if opts[:lose_response], do: {:error, :outcome_unknown}, else: {:ok, :deleted}
      end
    end
  end

  setup do
    {:ok, account} =
      Manifold.Accounts.create_account(%{address: "test-#{Ecto.UUID.generate()}@example.test"})

    {:ok, c} =
      ICloud.connect(%{
        account_id: account.id,
        apple_id: "test@icloud.com",
        app_password: "password",
        calendars_enabled: false
      })

    Process.put(:remote, %{})
    Process.put(:writes, [])
    assert :ok = Sync.run(c.id, c.generation, client: Server)
    [collection] = ICloud.collections(c.id, "contacts")
    {:ok, c} = ICloud.update_connection(c.id, %{default_contacts_collection_id: collection.id})
    %{account: account, connection: c, collection: collection}
  end

  defp run(c, opts \\ []), do: Sync.run(c.id, c.generation, Keyword.put(opts, :client, Server))
  defp resource(contact), do: Repo.get!(DAVResource, Repo.get!(Contact, contact.id).resource_id)

  test "authorization failure during reads prevents writes using stale service status", %{
    account: account,
    connection: c
  } do
    {:ok, contact} = Contacts.create_contact(%{full_name: "Pending", account_id: account.id})
    assert {:error, :unauthorized} = run(c, unauthorized_contacts: true)
    assert Process.get(:writes) == []
    assert resource(contact).status == "pending"
    assert Repo.get!(ICloudConnection, c.id).contacts_status == "reconnect_required"
  end

  test "write authorization and throttling update connection admission", %{
    account: account,
    connection: c
  } do
    {:ok, contact} = Contacts.create_contact(%{full_name: "Pending", account_id: account.id})
    assert {:error, {:rate_limited, 600}} = run(c, write_error: {:rate_limited, 600})
    assert {:error, :rate_limited} = ICloud.sync_now(c.id)
    assert ICloud.cooldown_seconds(Repo.get!(ICloudConnection, c.id)) > 500
    assert resource(contact).status == "failed"

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(ICloudConnection, c.id), next_sync_at: DateTime.utc_now())
    )

    Repo.update!(Ecto.Changeset.change(resource(contact), retry_at: nil))
    assert {:error, :unauthorized} = run(c, write_error: :unauthorized)
    assert Repo.get!(ICloudConnection, c.id).contacts_status == "reconnect_required"
    assert {:error, :reconnect_required} = ICloud.sync_now(c.id)
  end

  test "local create update delete converge asynchronously with stable identity", %{
    account: account,
    connection: c
  } do
    {:ok, contact} = Contacts.create_contact(%{full_name: "Local Ada", account_id: account.id})
    assert Process.get(:remote) == %{}
    original = resource(contact)
    assert original.status == "pending"
    assert :ok = run(c)
    assert resource(contact).status == "synced"
    assert Process.get(:remote)[original.href].content =~ "FN:Local Ada"
    {:ok, _} = Contacts.update_contact(contact.id, %{full_name: "Updated Ada"})
    assert :ok = run(c)
    assert Process.get(:remote)[original.href].content =~ "FN:Updated Ada"
    assert resource(contact).href == original.href
    {:ok, _} = Contacts.delete_contact(contact.id)
    assert Contacts.get_contact(contact.id) == nil
    assert Map.has_key?(Process.get(:remote), original.href)
    assert :ok = run(c)
    refute Map.has_key?(Process.get(:remote), original.href)
    assert resource(contact).acknowledged_revision == resource(contact).desired_revision
  end

  test "lost create response reconciles without a duplicate PUT after restart", %{
    account: account,
    connection: c
  } do
    {:ok, contact} =
      Contacts.create_contact(%{full_name: "Lost response", account_id: account.id})

    assert {:error, :outcome_unknown} = run(c, lose_response: true)
    assert resource(contact).status == "uncertain"
    assert map_size(Process.get(:remote)) == 1
    Repo.update_all(DAVResource, set: [retry_at: nil])
    assert :ok = run(c)
    assert resource(contact).status == "synced"
    assert length(Process.get(:writes)) == 1
    assert map_size(Process.get(:remote)) == 1
  end

  test "crash before write retries the persisted href and payload after confirming absence", %{
    account: account,
    connection: c
  } do
    {:ok, contact} = Contacts.create_contact(%{full_name: "Pending", account_id: account.id})
    original = resource(contact)
    assert {:error, :outcome_unknown} = run(c, fail_before_write: true)
    assert Process.get(:remote) == %{}
    Repo.update_all(DAVResource, set: [retry_at: nil])
    assert :ok = run(c)
    assert Map.keys(Process.get(:remote)) == [original.href]
    assert resource(contact).status == "synced"

    assert Enum.all?(Process.get(:writes), fn {:put, href, :create, _} ->
             href == original.href
           end)
  end

  test "acknowledging an older request retains an edit made during network IO", %{
    account: account,
    connection: c
  } do
    {:ok, contact} = Contacts.create_contact(%{full_name: "First", account_id: account.id})

    assert :ok =
             run(c,
               on_write: fn ->
                 assert {:ok, _} = Contacts.update_contact(contact.id, %{full_name: "Second"})
               end
             )

    state = resource(contact)
    assert state.acknowledged_revision == 1
    assert state.desired_revision == 2
    assert state.status == "pending"
    assert Contacts.get_contact(contact.id).full_name == "Second"
    assert :ok = run(c)
    assert Process.get(:remote)[state.href].content =~ "FN:Second"
    assert resource(contact).status == "synced"
  end

  test "remote changes conflict with local drafts and explicit local resolution is conditional",
       %{account: account, connection: c} do
    {:ok, contact} = Contacts.create_contact(%{full_name: "Base", account_id: account.id})
    :ok = run(c)
    state = resource(contact)
    {:ok, _} = Contacts.update_contact(contact.id, %{full_name: "Local"})
    remote = Process.get(:remote)[state.href]

    Process.put(:remote, %{
      state.href => %{
        content: String.replace(remote.content, "FN:Base", "FN:Remote"),
        etag: "\"remote\""
      }
    })

    assert :ok = run(c)
    assert resource(contact).status == "conflict"
    assert Contacts.get_contact(contact.id).full_name == "Local"
    assert length(Process.get(:writes)) == 1
    assert {:ok, _} = Outbound.resolve(state.id, :local)
    assert :ok = run(c)
    assert Process.get(:remote)[state.href].content =~ "FN:Local"
    assert [{:put, _, "\"remote\"", _} | _] = Process.get(:writes)
  end

  test "opted-out contact stays local and deleted local view never resurrects", %{
    account: account,
    connection: c
  } do
    {:ok, contact} = Contacts.create_contact(%{full_name: "Base", account_id: account.id})
    :ok = run(c)
    state = resource(contact)

    {:ok, _} =
      Contacts.update_contact(contact.id, %{sync_to_icloud: false, full_name: "Local only"})

    remote = Process.get(:remote)[state.href]

    Process.put(:remote, %{
      state.href => %{
        content: String.replace(remote.content, "FN:Base", "FN:Remote"),
        etag: "\"remote\""
      }
    })

    assert :ok = run(c)
    assert Contacts.get_contact(contact.id).full_name == "Local only"
    assert length(Process.get(:writes)) == 1
    {:ok, _} = Contacts.delete_contact(contact.id)
    assert :ok = run(c)
    assert Contacts.list_contacts() == []
    assert map_size(Process.get(:remote)) == 1
    assert Repo.aggregate(Contact, :count) == 1
  end

  test "account disable during admitted request fences the acknowledgement", %{
    account: account,
    connection: c
  } do
    {:ok, contact} = Contacts.create_contact(%{full_name: "Race", account_id: account.id})

    assert {:error, :stale} =
             run(c, on_write: fn -> Manifold.AccountLifecycle.disable_account(account.id) end)

    assert resource(contact).sent_revision == 1
    assert map_size(Process.get(:remote)) == 1
    stored = Repo.get!(ICloudConnection, c.id)
    refute stored.enabled
    assert {:error, :account_disabled} = run(stored)
  end

  test "legacy mailbox sync never admits Calendar reads or writes", %{connection: original} do
    {:ok, connection} =
      ICloud.update_connection(original.id, %{contacts_enabled: false, calendars_enabled: true})

    {:ok, calendar} = Manifold.Calendars.create_calendar(%{name: "Independent"})
    {:ok, event} = Manifold.Calendars.create_event(calendar.id, %{starts_at: "20261010T100000Z"})
    assert {:error, :disabled} = run(connection)
    assert Manifold.Calendars.get_event(event.id).id == event.id
    assert Process.get(:writes) == []
    assert Repo.get_by(DAVResource, kind: "calendars") == nil
    assert Enum.all?(Manifold.Calendars.list_calendars(), &(&1.id == calendar.id))
  end

  test "a newer repeated-property edit rebases IDs after an older removal is acknowledged", %{
    account: account,
    connection: c,
    collection: collection
  } do
    href = collection.href <> "multi.vcf"

    raw =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:multi\r\nFN:Multi\r\nEMAIL;TYPE=HOME;X-FIRST=keep:first@example.test\r\nEMAIL;TYPE=WORK;X-SECOND=keep:second@example.test\r\nEND:VCARD\r\n"

    Process.put(:remote, %{href => %{content: raw, etag: "\"initial\""}})
    assert :ok = run(c)
    contact = Enum.find(Contacts.list_contacts(account_id: account.id), &(&1.uid == "multi"))
    [_first, second] = contact.emails
    {:ok, _} = Contacts.update_contact(contact.id, %{emails: [second]})

    assert :ok =
             run(c,
               on_write: fn ->
                 current = Contacts.get_contact(contact.id)
                 [email] = current.emails

                 {:ok, _} =
                   Contacts.update_contact(contact.id, %{
                     emails: [Map.put(email, "value", "new@example.test")]
                   })
               end
             )

    assert resource(contact).status == "pending"
    assert :ok = run(c)
    remote = Process.get(:remote)[href].content
    assert remote =~ "EMAIL;TYPE=WORK;X-SECOND=keep:new@example.test"
    refute remote =~ "X-FIRST"
    assert resource(contact).status == "synced"
  end

  test "uncertain delete observes new remote version and never deletes it", %{
    account: account,
    connection: c
  } do
    {:ok, contact} = Contacts.create_contact(%{full_name: "Base", account_id: account.id})
    :ok = run(c)
    state = resource(contact)
    {:ok, _} = Contacts.delete_contact(contact.id)
    assert {:error, :outcome_unknown} = run(c, lose_response: true)
    Process.put(:remote, %{state.href => %{content: state.base_raw, etag: "\"another-client\""}})
    Repo.update_all(DAVResource, set: [retry_at: nil])
    assert :ok = run(c)
    assert resource(contact).status == "conflict"
    assert Process.get(:remote)[state.href].etag == "\"another-client\""
    assert Enum.count(Process.get(:writes), &match?({:delete, _, _}, &1)) == 1
  end

  test "re-enabling synchronization detects intervening remote changes", %{
    account: account,
    connection: c
  } do
    {:ok, contact} = Contacts.create_contact(%{full_name: "Base", account_id: account.id})
    :ok = run(c)
    state = resource(contact)

    {:ok, _} =
      Contacts.update_contact(contact.id, %{sync_to_icloud: false, full_name: "Local paused"})

    Process.put(:remote, %{
      state.href => %{
        content: String.replace(state.base_raw, "FN:Base", "FN:Remote paused"),
        etag: "\"remote\""
      }
    })

    :ok = run(c)
    {:ok, _} = Contacts.update_contact(contact.id, %{sync_to_icloud: true})
    assert :ok = run(c)
    assert resource(contact).status == "conflict"
    assert Contacts.get_contact(contact.id).full_name == "Local paused"
    assert {:ok, _} = Outbound.resolve(state.id, :remote)
    assert Contacts.get_contact(contact.id).full_name == "Remote paused"
  end
end
