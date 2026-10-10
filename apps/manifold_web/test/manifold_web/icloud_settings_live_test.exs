defmodule ManifoldWeb.ICloudSettingsLiveTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors.ICloud
  alias Manifold.Data.Schema.{Contact, DAVCollection, DAVResource, ICloudConnection}
  alias Manifold.Repo

  setup do
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})
    :ok
  end

  test "legacy URL guides Account setup without independent credential creation", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/icloud")
    assert has_element?(view, "#settings-nav[data-current='icloud']")
    assert has_element?(view, "#icloud-empty")
    assert has_element?(view, "a[href='/settings/accounts']")
    assert has_element?(view, "#icloud-create-account[href='/settings/accounts/new']")
    refute has_element?(view, "#icloud-form")
    refute has_element?(view, "input[type='password']")
  end

  test "legacy imported identities pause until explicitly assigned to a chosen Account", %{
    conn: conn
  } do
    {:ok, account} =
      Accounts.create_account(%{name: "Local Account", address: "local@example.test"})

    connection =
      Repo.insert!(%ICloudConnection{
        apple_id: "different-apple@example.test",
        password_ciphertext: <<1, 2, 3>>
      })

    collection =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "contacts",
        href: "https://contacts.icloud.com/book/",
        name: "Book"
      })

    resource =
      Repo.insert!(%DAVResource{
        kind: "contacts",
        connection_id: connection.id,
        collection_id: collection.id,
        href: "https://contacts.icloud.com/book/ada.vcf",
        uid: "ada",
        base_raw: "original",
        status: "paused"
      })

    imported =
      Repo.insert!(%Contact{
        collection_id: collection.id,
        resource_id: resource.id,
        resource_href: resource.href,
        uid: "ada",
        full_name: "Imported Ada"
      })

    {:ok, view, _} = live(conn, ~p"/settings/icloud")
    assert has_element?(view, "#icloud-#{connection.id}", "Account assignment required")

    view
    |> form("#icloud-assign-#{connection.id}", assignment: %{account_id: account.id})
    |> render_submit()

    assert_redirect(view, ~p"/settings/accounts/#{account.id}")
    assert ICloud.for_account(account.id).id == connection.id
    assert Repo.get!(Contact, imported.id).account_id == account.id
    assert Repo.get!(DAVResource, resource.id).desired_revision == 0
    assert Repo.get!(DAVResource, resource.id).acknowledged_revision == 0
  end

  test "blank assignment reports a sanitized error and bound connections link to their Account",
       %{conn: conn} do
    {:ok, account} = Accounts.create_account(%{name: "Bound", address: "bound@example.test"})

    {:ok, bound} =
      ICloud.connect(%{
        account_id: account.id,
        apple_id: "apple@example.test",
        app_password: "test-secret"
      })

    legacy =
      Repo.insert!(%ICloudConnection{apple_id: "legacy@example.test", password_ciphertext: <<1>>})

    {:ok, view, _} = live(conn, ~p"/settings/icloud")

    assert has_element?(
             view,
             "#manage-icloud-#{bound.id}[href='/settings/accounts/#{account.id}']"
           )

    view |> form("#icloud-assign-#{legacy.id}", assignment: %{account_id: ""}) |> render_submit()
    assert render(view) =~ "Unable to assign this connection"
    assert Repo.get!(ICloudConnection, legacy.id).account_id == nil
  end
end
