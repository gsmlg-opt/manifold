defmodule ManifoldWeb.ContactLiveTest do
  use ManifoldWeb.ConnCase, async: true

  alias Manifold.Contacts
  alias Manifold.Data.Schema.{Contact, DAVCollection, ICloudConnection}
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
end
