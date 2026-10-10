defmodule ManifoldWeb.AccountICloudLiveTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors.ICloud
  alias Manifold.Contacts
  alias Manifold.Data.Schema.{Contact, DAVCollection, ICloudConnection}
  alias Manifold.Repo

  setup do
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})

    {:ok, account} =
      Accounts.create_account(%{name: "Local Account", address: "local@example.test"})

    %{account: account}
  end

  test "Account-owned connection setup clears secrets and preserves mail configuration", %{
    conn: conn,
    account: account
  } do
    {:ok, view, _} = live(conn, ~p"/settings/accounts/#{account.id}")
    assert has_element?(view, "#account-icloud", "iCloud Contacts and Calendar")
    assert has_element?(view, "#receive-methods")
    assert has_element?(view, "#send-methods")
    assert has_element?(view, "input[name='icloud[contacts_enabled]'][type='checkbox'][checked]")
    password = "never-render-test-password"

    view
    |> form("#icloud-form",
      icloud: %{
        apple_id: "different-apple@example.test",
        app_password: password,
        contacts_enabled: "true",
        calendars_enabled: "false"
      }
    )
    |> render_submit()

    assert_push_event(view, "clear-icloud-password", %{})
    connection = ICloud.for_account(account.id)
    assert connection.account_id == account.id
    assert connection.apple_id == "different-apple@example.test"
    assert connection.contacts_enabled
    refute connection.calendars_enabled
    assert length(Accounts.list_accounts()) == 1
    assert has_element?(view, "input[name='icloud[app_password]'][value='']")
    assert render(view) =~ "iCloud settings saved"
    refute render(view) =~ password
    refute Map.has_key?(connection, :password_ciphertext)
    assert has_element?(view, "#receive-methods")
    assert has_element?(view, "#send-methods")
  end

  test "default destination enrollment and service toggles stay inside the Account", %{
    conn: conn,
    account: account
  } do
    {:ok, contact} =
      Contacts.create_contact(%{full_name: "Waiting locally", account_id: account.id})

    {:ok, connection} =
      ICloud.connect(%{
        account_id: account.id,
        apple_id: "apple@example.test",
        app_password: "test-password"
      })

    collection =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "contacts",
        href: "https://contacts.icloud.com/book/",
        name: "Personal",
        writable: true
      })

    {:ok, view, _} = live(conn, ~p"/settings/accounts/#{account.id}")

    view
    |> form("#icloud-form",
      icloud: %{
        default_contacts_collection_id: collection.id,
        app_password: "replacement-test-password"
      }
    )
    |> render_submit()

    assert Contacts.get_contact(contact.id).resource.status == "pending"
    assert ICloud.for_account(account.id).default_contacts_collection_id == collection.id
    refute render(view) =~ "replacement-test-password"
    view |> element("#toggle-icloud-#{connection.id}") |> render_click()
    refute ICloud.for_account(account.id).enabled
    assert render(view) =~ "iCloud connection updated"
    assert has_element?(view, "#sync-icloud-#{connection.id}[disabled]")
    view |> element("#toggle-icloud-#{connection.id}") |> render_click()
    assert ICloud.for_account(account.id).enabled
    view |> element("#sync-icloud-#{connection.id}") |> render_click()
    assert render(view) =~ "Synchronization queued"

    view
    |> form("#icloud-form", icloud: %{contacts_enabled: "false", calendars_enabled: "false"})
    |> render_submit()

    refute ICloud.for_account(account.id).contacts_enabled
    refute ICloud.for_account(account.id).calendars_enabled
  end

  test "invalid credentials clear the form and disconnect retains imported local data", %{
    conn: conn,
    account: account
  } do
    {:ok, view, _} = live(conn, ~p"/settings/accounts/#{account.id}")

    view
    |> form("#icloud-form", icloud: %{apple_id: "", app_password: "invalid-never-render"})
    |> render_submit()

    assert has_element?(view, "#icloud-form-error")
    assert has_element?(view, "input[name='icloud[app_password]'][value='']")
    refute render(view) =~ "invalid-never-render"
    assert ICloud.for_account(account.id) == nil

    view
    |> form("#icloud-form",
      icloud: %{apple_id: "apple@example.test", app_password: "valid-test-password"}
    )
    |> render_submit()

    connection = ICloud.for_account(account.id)

    collection =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "contacts",
        href: "https://contacts.icloud.com/book/",
        name: "Book"
      })

    imported =
      Repo.insert!(%Contact{
        account_id: account.id,
        collection_id: collection.id,
        resource_href: "https://contacts.icloud.com/book/one.vcf",
        full_name: "Imported"
      })

    view |> element("#disconnect-icloud-#{connection.id}") |> render_click()
    assert has_element?(view, "#icloud-disconnect-dialog", "Your iCloud data is unchanged")
    view |> element("#cancel-icloud-disconnect") |> render_click()
    refute has_element?(view, "#icloud-disconnect-dialog")
    view |> element("#disconnect-icloud-#{connection.id}") |> render_click()
    view |> element("#confirm-icloud-disconnect") |> render_click()
    assert Repo.get(ICloudConnection, connection.id) == nil
    assert render(view) =~ "iCloud disconnected. Local contacts and events retained."
    assert Contacts.get_contact(imported.id)
    assert Contacts.get_contact(imported.id).collection_id == nil
    assert has_element?(view, "input[name='icloud[apple_id]']:not([readonly])")
  end
end
