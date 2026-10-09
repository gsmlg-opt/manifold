defmodule ManifoldWeb.ICloudSettingsLiveTest do
  use ManifoldWeb.ConnCase, async: true

  alias Manifold.Connectors.ICloud
  alias Manifold.Contacts
  alias Manifold.Data.Schema.{Contact, DAVCollection, ICloudConnection}
  alias Manifold.Repo

  test "iCloud settings help and navigation", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/icloud")
    assert has_element?(view, "#settings-nav[data-current='icloud']")
    assert has_element?(view, "#icloud-empty")
    assert has_element?(view, "input[type='password'][name='icloud[app_password]'][value='']")
    assert has_element?(view, "a[href='https://support.apple.com/en-us/121539']")
    assert has_element?(view, "#icloud-settings", "read-only")
  end

  test "connect, replace credentials and disable without displaying secrets", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/icloud")
    password = "test-app-password-never-render"

    view
    |> form("#icloud-form",
      icloud: %{
        apple_id: "ui@example.test",
        app_password: password,
        contacts_enabled: "true",
        calendars_enabled: "false"
      }
    )
    |> render_submit()

    assert_push_event(view, "clear-icloud-password", %{})
    [connection] = ICloud.list_connections()
    assert has_element?(view, "#icloud-#{connection.id}", "ui@example.test")
    assert connection.contacts_enabled
    refute connection.calendars_enabled
    assert has_element?(view, "input[name='icloud[app_password]'][value='']")
    refute render(view) =~ password
    refute Map.has_key?(connection, :password_ciphertext)

    view |> element("#edit-icloud-#{connection.id}") |> render_click()
    assert has_element?(view, "input[name='icloud[apple_id]'][readonly]")

    view
    |> form("#icloud-form",
      icloud: %{app_password: "replacement-test-secret", calendars_enabled: "true"}
    )
    |> render_submit()

    refute render(view) =~ "replacement-test-secret"
    assert has_element?(view, "input[name='icloud[app_password]'][value='']")
    view |> element("#toggle-icloud-#{connection.id}") |> render_click()
    refute hd(ICloud.list_connections()).enabled
    assert has_element?(view, "#sync-icloud-#{connection.id}[disabled]")
    view |> element("#toggle-icloud-#{connection.id}") |> render_click()
    assert hd(ICloud.list_connections()).enabled
    view |> element("#sync-icloud-#{connection.id}") |> render_click()
    assert render(view) =~ "Synchronization queued"
  end

  test "invalid settings clear password and report sanitized failure", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/icloud")

    render_submit(view, "connect", %{
      "icloud" => %{
        "apple_id" => "",
        "app_password" => "do-not-show-invalid-secret",
        "contacts_enabled" => "true",
        "calendars_enabled" => "true"
      }
    })

    assert_push_event(view, "clear-icloud-password", %{})
    assert has_element?(view, "#icloud-form-error")
    assert has_element?(view, "input[name='icloud[app_password]'][value='']")
    refute render(view) =~ "do-not-show-invalid-secret"
  end

  test "disconnect confirmation removes imports but retains local contacts", %{conn: conn} do
    {:ok, local} = Contacts.create_contact(%{full_name: "Local survives"})

    {:ok, connection} =
      ICloud.connect(%{
        apple_id: "disconnect@example.test",
        app_password: "test-secret",
        contacts_enabled: true,
        calendars_enabled: false
      })

    collection =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "contacts",
        href: "https://contacts.icloud.com/book/",
        name: "Book"
      })

    imported =
      Repo.insert!(%Contact{
        collection_id: collection.id,
        resource_href: "https://contacts.icloud.com/book/one.vcf",
        full_name: "Imported",
        raw: "BEGIN:VCARD\nEND:VCARD"
      })

    {:ok, view, _} = live(conn, ~p"/settings/icloud")
    view |> element("#disconnect-icloud-#{connection.id}") |> render_click()
    assert has_element?(view, "#icloud-disconnect-dialog", "Your iCloud data is unchanged")
    assert Repo.get(ICloudConnection, connection.id)
    view |> element("#cancel-icloud-disconnect") |> render_click()
    refute has_element?(view, "#icloud-disconnect-dialog")
    view |> element("#disconnect-icloud-#{connection.id}") |> render_click()
    view |> element("#confirm-icloud-disconnect") |> render_click()
    assert is_nil(Repo.get(ICloudConnection, connection.id))
    assert is_nil(Contacts.get_contact(imported.id))
    assert Contacts.get_contact(local.id)
  end
end
