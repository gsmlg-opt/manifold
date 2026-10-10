defmodule ManifoldWeb.ContactLiveTest do
  use ManifoldWeb.ConnCase, async: true

  alias Manifold.Contacts
  alias Manifold.Data.Schema.{Contact, DAVCollection, DAVResource, ICloudConnection}
  alias Manifold.Repo

  test "empty contacts and application navigation", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/contacts")
    assert has_element?(view, "#contacts-empty")
    assert has_element?(view, "#app-appbar a[href='/calendars']")
    assert has_element?(view, "#app-appbar a[href='/contacts']")
  end

  test "local contact multiple-value creation, search, edit and deletion", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/contacts/new")
    view |> element("#add-emails") |> render_click()
    view |> element("#add-phones") |> render_click()
    view |> element("#add-addresses") |> render_click()
    assert has_element?(view, "#emails-0-value")
    assert has_element?(view, "#phones-0-value")
    assert has_element?(view, "#addresses-0-street")

    view
    |> form("#contact-form",
      contact: %{
        full_name: "Ada Lovelace",
        given_name: "Ada",
        family_name: "Lovelace",
        organization: "Analytical Engines",
        notes: "First programmer",
        emails: %{"0" => %{value: "ada@example.test", label: "Work"}},
        phones: %{"0" => %{value: "+44 12345", label: "Mobile"}},
        addresses: %{
          "0" => %{
            street: "1 Engine Way",
            locality: "London",
            postal_code: "N1",
            country: "UK",
            label: "Home"
          }
        }
      }
    )
    |> render_submit()

    [contact] = Contacts.list_contacts(search: "Ada")
    assert_patch(view, ~p"/contacts/#{contact.id}")
    assert has_element?(view, "#contact-detail", "ada@example.test")
    assert has_element?(view, "#contact-detail", "London")

    view |> form("#contact-search", search: "Nobody") |> render_change()
    assert has_element?(view, "#contacts-empty")
    view |> form("#contact-search", search: "Ada") |> render_change()
    assert has_element?(view, "#contact-#{contact.id}")

    view |> element("#edit-contact") |> render_click()
    assert_patch(view, ~p"/contacts/#{contact.id}/edit")
    view |> form("#contact-form", contact: %{full_name: "Countess Lovelace"}) |> render_submit()
    assert_patch(view, ~p"/contacts/#{contact.id}")
    assert Contacts.get_contact(contact.id).full_name == "Countess Lovelace"

    assert Contacts.get_contact(contact.id).emails == [
             %{"value" => "ada@example.test", "label" => "Work"}
           ]

    render_click(view, "delete")
    assert_patch(view, ~p"/contacts")
    assert is_nil(Contacts.get_contact(contact.id))
  end

  test "imported source identity is visible and edits and deletes are refused", %{conn: conn} do
    connection =
      Repo.insert!(%ICloudConnection{
        apple_id: "apple@example.test",
        password_ciphertext: <<1, 2, 3>>
      })

    collection =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "contacts",
        href: "https://contacts.icloud.com/book/",
        name: "Personal"
      })

    contact =
      Repo.insert!(%Contact{
        collection_id: collection.id,
        resource_href: "https://contacts.icloud.com/book/ada.vcf",
        full_name: "Cloud Ada",
        uid: "cloud-ada",
        raw: "BEGIN:VCARD\nEND:VCARD",
        etag: "one"
      })

    {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
    assert has_element?(view, "#contact-detail", "apple@example.test")
    assert has_element?(view, "#contact-detail", "Personal")
    assert has_element?(view, "#contact-read-only")
    refute has_element?(view, "#edit-contact")
    refute has_element?(view, "#delete-contact")
    render_click(view, "delete")
    assert Contacts.get_contact(contact.id)

    assert {:error, {:live_redirect, %{to: target}}} =
             live(conn, ~p"/contacts/#{contact.id}/edit")

    assert target == ~p"/contacts/#{contact.id}"
  end

  test "failed contact save retains input and reports validation", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/contacts/new")
    view |> form("#contact-form", contact: %{full_name: ""}) |> render_submit()
    assert has_element?(view, "[role='alert']", "Unable to save contact")
    assert Contacts.list_contacts() == []
  end

  test "a read-only import can pause synchronization without changing its content", %{conn: conn} do
    {account, collection} = target_fixture()
    collection |> Ecto.Changeset.change(writable: false) |> Repo.update!()

    contact =
      Repo.insert!(%Contact{
        account_id: account.id,
        collection_id: collection.id,
        resource_href: "https://contacts.icloud.com/book/readonly.vcf",
        uid: "readonly",
        full_name: "Read-only original",
        emails: [%{"value" => "original@example.test"}],
        raw: "original provider document"
      })

    {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
    refute has_element?(view, "#edit-contact")
    assert has_element?(view, "#contact-sync-enabled[checked]")

    view
    |> form("#contact-sync-preference", preference: %{sync_to_icloud: "false"})
    |> render_submit()

    updated = Contacts.get_contact(contact.id)
    refute updated.sync_to_icloud
    assert updated.full_name == contact.full_name
    assert updated.emails == contact.emails
    assert updated.raw == contact.raw
    assert updated.resource.status == "paused"
    assert updated.resource.collection_id == collection.id
    assert has_element?(view, "#contact-sync-status", "off")
    refute has_element?(view, "#contact-sync-enabled[checked]")

    view
    |> form("#contact-sync-preference", preference: %{sync_to_icloud: "true"})
    |> render_submit()

    resumed = Contacts.get_contact(contact.id)
    assert resumed.sync_to_icloud
    assert resumed.resource_id == updated.resource_id
    assert resumed.full_name == contact.full_name
    assert resumed.emails == contact.emails
    assert resumed.raw == contact.raw
    refute has_element?(view, "#edit-contact")
    assert has_element?(view, "#contact-sync-enabled[checked]")
  end

  test "default sync preference and Account selection commit offline then opt-out pauses the same binding",
       %{conn: conn} do
    {account, _} = target_fixture()
    {:ok, view, _} = live(conn, ~p"/contacts/new")
    assert has_element?(view, "input[name='contact[sync_to_icloud]'][type='checkbox'][checked]")
    assert has_element?(view, "select[name='contact[account_id]'] option[value='#{account.id}']")

    view
    |> form("#contact-form", contact: %{full_name: "Offline Ada", account_id: account.id})
    |> render_submit()

    [contact] = Contacts.list_contacts()
    assert contact.sync_to_icloud
    assert contact.account_id == account.id
    assert contact.resource.status == "pending"
    assert has_element?(view, "#contact-sync-status", "Pending")
    view |> element("#edit-contact") |> render_click()

    view
    |> form("#contact-form", contact: %{full_name: "Local draft", sync_to_icloud: "false"})
    |> render_submit()

    updated = Contacts.get_contact(contact.id)
    assert updated.full_name == "Local draft"
    refute updated.sync_to_icloud
    assert updated.resource_id == contact.resource_id
    assert updated.resource.status == "paused"
    assert has_element?(view, "#contact-sync-status", "off")
  end

  test "writable imported contact editing keeps multi-value property identity and offers Account copy",
       %{conn: conn} do
    {account, collection} = target_fixture()

    imported =
      Repo.insert!(%Contact{
        account_id: account.id,
        collection_id: collection.id,
        resource_href: "https://contacts.icloud.com/book/ada.vcf",
        full_name: "Cloud Ada",
        uid: "cloud-ada",
        raw: "original document",
        emails: [
          %{"value" => "ada@example.test", "property_id" => "item1.EMAIL", "label" => "Work"}
        ]
      })

    {:ok, view, _} = live(conn, ~p"/contacts/#{imported.id}")
    assert has_element?(view, "#edit-contact")
    refute has_element?(view, "#contact-read-only")
    view |> element("#edit-contact") |> render_click()
    view |> form("#contact-form", contact: %{full_name: "Edited locally"}) |> render_submit()
    updated = Contacts.get_contact(imported.id)
    assert updated.full_name == "Edited locally"
    assert updated.resource.status == "pending"
    assert hd(updated.emails)["property_id"] == "item1.EMAIL"
    view |> form("#contact-copy-form", copy: %{account_id: ""}) |> render_submit()
    copies = Contacts.list_contacts()
    assert length(copies) == 2
    assert Enum.any?(copies, &(&1.id != imported.id and is_nil(&1.resource_id)))
  end

  test "conflict choices retain a local draft or project the selected iCloud version", %{
    conn: conn
  } do
    {account, _} = target_fixture()

    for choice <- ["local", "remote"] do
      {:ok, contact} =
        Contacts.create_contact(%{full_name: "Local draft #{choice}", account_id: account.id})

      resource = Repo.get!(DAVResource, contact.resource_id)

      remote =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:#{resource.uid}\r\nFN:Remote Ada\r\nEND:VCARD\r\n"

      resource
      |> DAVResource.changeset(%{status: "conflict", remote_raw: remote, remote_etag: "\"new\""})
      |> Repo.update!()

      {:ok, view, _} = live(conn, ~p"/contacts/#{contact.id}")
      assert has_element?(view, "#contact-conflict")

      view
      |> element(if(choice == "local", do: "#contact-use-local", else: "#contact-use-icloud"))
      |> render_click()

      refute has_element?(view, "#contact-conflict")
      updated = Contacts.get_contact(contact.id)
      assert updated.resource.status == if(choice == "local", do: "pending", else: "synced")

      assert updated.full_name ==
               if(choice == "local", do: "Local draft local", else: "Remote Ada")
    end
  end

  defp target_fixture do
    name = "ui#{System.unique_integer([:positive])}.example.test"
    domain = Repo.insert!(%Manifold.Accounts.Schema.Domain{name: name, normalized_domain: name})

    account =
      Repo.insert!(%Manifold.Accounts.Schema.Account{
        domain_id: domain.id,
        local_part: "ada",
        canonical_local_part: "ada",
        name: "Local Account"
      })

    connection =
      Repo.insert!(%ICloudConnection{
        account_id: account.id,
        apple_id: "apple@example.test",
        password_ciphertext: <<1, 2, 3>>
      })

    collection =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "contacts",
        href: "https://contacts.icloud.com/book/",
        name: "Personal",
        writable: true
      })

    connection
    |> Ecto.Changeset.change(default_contacts_collection_id: collection.id)
    |> Repo.update!()

    {account, collection}
  end

  test "a deleted contact conflict remains discoverable and Use iCloud restores the remote version",
       %{conn: conn} do
    {account, _} = target_fixture()
    {:ok, contact} = Contacts.create_contact(%{full_name: "Delete draft", account_id: account.id})
    resource = Repo.get!(DAVResource, contact.resource_id)

    raw =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:#{resource.uid}\r\nFN:Restored from iCloud\r\nEND:VCARD\r\n"

    contact |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

    resource
    |> DAVResource.changeset(%{
      status: "conflict",
      operation: "delete",
      remote_raw: raw,
      remote_etag: "\"changed\""
    })
    |> Repo.update!()

    assert Contacts.get_contact(contact.id) == nil
    {:ok, view, _} = live(conn, ~p"/contacts")
    assert has_element?(view, "#contact-#{contact.id}", "Deletion conflict")
    view |> element("#contact-#{contact.id} a") |> render_click()
    assert has_element?(view, "#contact-conflict")
    refute has_element?(view, "#delete-contact")
    view |> element("#contact-use-icloud") |> render_click()
    assert Contacts.get_contact(contact.id).full_name == "Restored from iCloud"
    assert Contacts.get_contact(contact.id).deleted_at == nil
  end
end
