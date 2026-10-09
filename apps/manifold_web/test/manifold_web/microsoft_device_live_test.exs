defmodule ManifoldWeb.MicrosoftDeviceLiveTest do
  use ManifoldWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Schema.OAuthDeviceTransaction
  alias Manifold.Repo

  setup do
    previous = Application.get_env(:manifold_connectors, :providers)

    microsoft =
      previous
      |> Keyword.fetch!(:microsoft)
      |> Keyword.put(:req_options, plug: {Req.Test, __MODULE__})

    Application.put_env(
      :manifold_connectors,
      :providers,
      Keyword.put(previous, :microsoft, microsoft)
    )

    on_exit(fn -> Application.put_env(:manifold_connectors, :providers, previous) end)

    {:ok, account} =
      Accounts.create_account(%{name: "Device login", address: "device@outlook.com"})

    {:ok, _} =
      Connectors.put_oauth_provider_setting("microsoft", %{
        client_id: "public-client",
        auth_flow: "device_code"
      })

    {:ok, account: account}
  end

  test "device login shows only the user code and completes a send connection through Graph", %{
    conn: conn,
    account: account
  } do
    owner = stub_graph()

    {:ok, view, _} = live(conn, "/settings/accounts/#{account.id}/microsoft/device?purpose=send")
    Req.Test.allow(__MODULE__, owner, view.pid)
    view |> element("#start-microsoft-device") |> render_click()
    html = render_async(view)
    assert_receive :device_requested
    assert has_element?(view, "#microsoft-device-user-code[value='ABCD-EFGH']")

    assert has_element?(
             view,
             "#microsoft-device-verification[href='https://login.microsoft.com/device']"
           )

    for private <- [
          "private-device-sentinel",
          "private-access-sentinel",
          "private-refresh-sentinel"
        ],
        do: refute(html =~ private)

    [transaction] = Repo.all(OAuthDeviceTransaction)

    Repo.update_all(from(d in OAuthDeviceTransaction, where: d.id == ^transaction.id),
      set: [next_poll_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    send(view.pid, {:poll_device, transaction.id})
    assert_redirect(view, "/settings/accounts/#{account.id}", 5_000)
    assert Repo.get!(OAuthDeviceTransaction, transaction.id).status == "complete"
    assert Repo.get!(OAuthDeviceTransaction, transaction.id).device_code_ciphertext == nil

    assert [%{kind: "microsoft", status: "connected"}] =
             Connectors.list_send_methods_for_account(account.id)
  end

  test "cancelling a pending login clears the private device code", %{
    conn: conn,
    account: account
  } do
    Req.Test.stub(__MODULE__, fn request ->
      Req.Test.json(request, %{
        device_code: "private-cancel-code",
        user_code: "CANCEL-CODE",
        verification_uri: "https://login.microsoft.com/device",
        expires_in: 900,
        interval: 60
      })
    end)

    {:ok, view, _} = live(conn, "/settings/accounts/#{account.id}/microsoft/device")
    Req.Test.allow(__MODULE__, self(), view.pid)
    view |> element("#start-microsoft-device") |> render_click()
    render_async(view)
    assert has_element?(view, "#microsoft-device-user-code")
    view |> element("#cancel-microsoft-device") |> render_click()
    assert has_element?(view, "#start-microsoft-device")
    refute has_element?(view, "#microsoft-device-user-code")

    assert [%{status: "cancelled", device_code_ciphertext: nil}] =
             Repo.all(OAuthDeviceTransaction)
  end

  test "cancel after atomic completion reports connection instead of cancellation", %{
    conn: conn,
    account: account
  } do
    owner = stub_graph()
    {:ok, view, _} = live(conn, "/settings/accounts/#{account.id}/microsoft/device?purpose=send")
    Req.Test.allow(__MODULE__, owner, view.pid)
    view |> element("#start-microsoft-device") |> render_click()
    render_async(view)
    [transaction] = Repo.all(OAuthDeviceTransaction)

    Repo.update_all(from(d in OAuthDeviceTransaction, where: d.id == ^transaction.id),
      set: [next_poll_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:ok, _method} = Manifold.Connectors.DeviceOAuth.poll(transaction.id)
    view |> element("#cancel-microsoft-device") |> render_click()
    assert_redirect(view, "/settings/accounts/#{account.id}")
    assert Repo.get!(OAuthDeviceTransaction, transaction.id).status == "complete"
  end

  test "Microsoft start dispatches to device login without creating a grant on GET", %{
    conn: conn,
    account: account
  } do
    conn = get(conn, "/connectors/microsoft/start", account_id: account.id, purpose: "send")
    assert redirected_to(conn) == "/settings/accounts/#{account.id}/microsoft/device?purpose=send"
    assert Repo.aggregate(OAuthDeviceTransaction, :count) == 0
  end

  test "device page waits for an explicit start and rejects an invalid purpose", %{
    conn: conn,
    account: account
  } do
    {:ok, view, html} =
      live(conn, "/settings/accounts/#{account.id}/microsoft/device?purpose=send")

    assert html =~ "Microsoft device-code login"
    assert html =~ "device@outlook.com"
    assert has_element?(view, "#start-microsoft-device")
    assert Repo.aggregate(OAuthDeviceTransaction, :count) == 0

    assert {:error, {:live_redirect, %{to: "/settings/accounts"}}} =
             live(conn, "/settings/accounts/#{account.id}/microsoft/device?purpose=invalid")
  end

  defp stub_graph do
    owner = self()

    Req.Test.stub(__MODULE__, fn request ->
      {:ok, bytes, request} = Plug.Conn.read_body(request)
      form = URI.decode_query(bytes)
      refute Map.has_key?(form, "client_secret")
      refute Map.has_key?(form, "redirect_uri")

      case request.request_path do
        "/devicecode" ->
          send(owner, :device_requested)

          Req.Test.json(request, %{
            device_code: "private-device-sentinel",
            user_code: "ABCD-EFGH",
            verification_uri: "https://login.microsoft.com/device",
            expires_in: 900,
            interval: 60
          })

        "/token" ->
          assert form["device_code"] == "private-device-sentinel"
          assert form["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code"

          Req.Test.json(request, %{
            access_token: "private-access-sentinel",
            refresh_token: "private-refresh-sentinel",
            expires_in: 3600,
            scope: "User.Read Mail.Send offline_access openid profile"
          })

        "/v1.0/me" ->
          Req.Test.json(request, %{id: "device-subject", mail: "device@outlook.com"})
      end
    end)

    owner
  end
end
