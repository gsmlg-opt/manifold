defmodule ManifoldWeb.OAuthSettingsLiveTest do
  use ManifoldWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Crypto

  alias Manifold.Connectors.Schema.{
    OAuthAuthorization,
    OAuthProviderSetting,
    ReceiveMethod,
    SendMethod
  }

  alias Manifold.Repo

  setup do
    previous_key = Application.get_env(:manifold_connectors, :encryption_key)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    on_exit(fn -> restore_env(:encryption_key, previous_key) end)

    :ok
  end

  test "Phoenix filters nested client secrets without weakening password and token filters" do
    sentinel = "filter-unit-secret-#{System.unique_integer([:positive])}"

    filtered =
      Phoenix.Logger.filter_values(%{
        "password" => "password-value",
        "token" => "token-value",
        "oauth_provider_setting" => %{
          "client_id" => "visible-client",
          "client_secret" => sentinel
        }
      })

    assert filtered == %{
             "password" => "[FILTERED]",
             "token" => "[FILTERED]",
             "oauth_provider_setting" => %{
               "client_id" => "visible-client",
               "client_secret" => "[FILTERED]"
             }
           }

    refute contains_binary?(filtered, sentinel)
  end

  test "LiveView debug event logs filter submitted client secrets", %{conn: conn} do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    {:ok, view, _html} = live(conn, "/settings/oauth")
    sentinel = "live-event-log-secret-#{System.unique_integer([:positive])}"

    log =
      capture_log([level: :debug], fn ->
        view
        |> form("#oauth-provider-gmail-form",
          provider: "gmail",
          oauth_provider_setting: %{
            client_id: "logged-client",
            client_secret: sentinel,
            lock_version: ""
          }
        )
        |> render_submit()
      end)

    assert log =~ "HANDLE EVENT"
    assert log =~ "[FILTERED]"
    refute log =~ sentinel
  end

  test "OAuth settings renders the catalog Gmail card and a secret-safe form", %{conn: conn} do
    {:ok, view, html} = live(conn, "/settings/oauth")

    callback_uri = "http://localhost:4002/connectors/gmail/callback"

    assert html =~ ~s(data-current="oauth")
    assert html =~ "OAuth"
    assert html =~ "Google OAuth"
    assert html =~ "Not configured"
    assert html =~ "/settings/oauth/gmail/help"
    assert html =~ "/settings/accounts"
    assert html =~ callback_uri

    assert has_element?(view, "#oauth-provider-gmail")
    assert has_element?(view, "#oauth-provider-gmail-form[phx-submit='save-provider']")
    refute has_element?(view, "#oauth-provider-gmail-form[phx-change]")

    assert has_element?(
             view,
             "button#save-oauth-provider-gmail.settings-action-primary[type='submit']",
             "Save changes"
           )

    refute has_element?(view, "#oauth-provider-gmail-form el-dm-button")

    assert has_element?(
             view,
             "#oauth-provider-gmail-client-secret[type='password'][autocomplete='new-password'][value=''][phx-patch-focused]"
           )

    assert has_element?(
             view,
             "#oauth-provider-gmail-callback[readonly][value='#{callback_uri}']"
           )

    refute html =~ "MANIFOLD_GMAIL_CLIENT_ID"
    refute html =~ "MANIFOLD_GMAIL_CLIENT_SECRET"
    refute html =~ "client_secret_ciphertext"
    refute html =~ "Administrators"
  end

  test "initial save immediately reloads configured state without retaining the secret", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/settings/oauth")
    secret = "initial-ui-secret-never-render"

    html =
      view
      |> form("#oauth-provider-gmail-form",
        provider: "gmail",
        oauth_provider_setting: %{
          client_id: "google-client",
          client_secret: secret,
          lock_version: ""
        }
      )
      |> render_submit()

    row = Repo.get_by!(OAuthProviderSetting, provider: "gmail")

    assert html =~ "Configured"
    assert html =~ "google-client"
    assert html =~ ~s(value="#{row.lock_version}")
    refute html =~ secret
    refute contains_binary?(socket_assigns(view), secret)
    refute contains_exact_binary?(socket_assigns(view), row.client_secret_ciphertext)

    assert {:ok, ^secret} =
             Crypto.decrypt(
               row.client_secret_ciphertext,
               "oauth_provider_setting:#{row.id}:client_secret"
             )
  end

  test "blank secret retains configured credentials and generation", %{conn: conn} do
    assert {:ok, initial} = put_setting("unchanged-client", "stored-secret-never-render")
    before = Repo.get_by!(OAuthProviderSetting, provider: "gmail")

    {:ok, view, html} = live(conn, "/settings/oauth")

    assert html =~ "Leave blank to keep the current secret."
    refute html =~ "stored-secret-never-render"

    html =
      view
      |> form("#oauth-provider-gmail-form",
        provider: "gmail",
        oauth_provider_setting: %{
          client_id: "unchanged-client",
          client_secret: "",
          lock_version: Integer.to_string(initial.lock_version)
        }
      )
      |> render_submit()

    after_save = Repo.get_by!(OAuthProviderSetting, provider: "gmail")

    assert html =~ "Configured"
    assert after_save.lock_version == initial.lock_version
    assert after_save.client_secret_ciphertext == before.client_secret_ciphertext
    refute html =~ "stored-secret-never-render"
    refute contains_binary?(socket_assigns(view), "stored-secret-never-render")
  end

  test "changed client ID requires a secret and validation never retains submitted secrets", %{
    conn: conn
  } do
    assert {:ok, initial} = put_setting("old-client", "stored-secret-never-render")
    {:ok, view, _html} = live(conn, "/settings/oauth")

    html =
      view
      |> form("#oauth-provider-gmail-form",
        provider: "gmail",
        oauth_provider_setting: %{
          client_id: "new-client",
          client_secret: "",
          lock_version: Integer.to_string(initial.lock_version)
        }
      )
      |> render_submit()

    assert html =~ "new-client"
    assert html =~ "can&#39;t be blank"

    assert has_element?(
             view,
             "#oauth-provider-gmail-client-secret[value='']"
           )

    validation_secret = "validation-secret-never-render"

    html =
      view
      |> form("#oauth-provider-gmail-form",
        provider: "gmail",
        oauth_provider_setting: %{
          client_id: "",
          client_secret: validation_secret,
          lock_version: Integer.to_string(initial.lock_version)
        }
      )
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    refute html =~ validation_secret
    refute contains_binary?(socket_assigns(view), validation_secret)
    refute contains_binary?(socket_assigns(view), "stored-secret-never-render")
    assert Repo.get_by!(OAuthProviderSetting, provider: "gmail").client_id == "old-client"
  end

  test "secret rotation advances the generation and never rerenders the new secret", %{conn: conn} do
    assert {:ok, initial} = put_setting("client", "old-secret-never-render")
    {:ok, view, _html} = live(conn, "/settings/oauth")
    rotated_secret = "rotated-secret-never-render"

    html =
      view
      |> form("#oauth-provider-gmail-form",
        provider: "gmail",
        oauth_provider_setting: %{
          client_id: "client",
          client_secret: rotated_secret,
          lock_version: Integer.to_string(initial.lock_version)
        }
      )
      |> render_submit()

    row = Repo.get_by!(OAuthProviderSetting, provider: "gmail")

    assert row.lock_version == initial.lock_version + 1

    assert {:ok, ^rotated_secret} =
             Crypto.decrypt(
               row.client_secret_ciphertext,
               "oauth_provider_setting:#{row.id}:client_secret"
             )

    assert html =~ "Configured"
    refute html =~ rotated_secret
    refute contains_binary?(socket_assigns(view), rotated_secret)
    refute contains_exact_binary?(socket_assigns(view), row.client_secret_ciphertext)
  end

  test "missing and integer stale snapshots reload current state with generic errors", %{
    conn: conn
  } do
    {:ok, missing_view, _html} = live(conn, "/settings/oauth")
    assert {:ok, created} = put_setting("winner-client", "winner-secret")

    missing_secret = "stale-missing-secret-never-render"

    html =
      missing_view
      |> form("#oauth-provider-gmail-form",
        provider: "gmail",
        oauth_provider_setting: %{
          client_id: "loser-client",
          client_secret: missing_secret,
          lock_version: ""
        }
      )
      |> render_submit()

    assert html =~ "OAuth configuration could not be saved."
    assert html =~ "winner-client"
    refute html =~ missing_secret
    refute html =~ "stale_oauth_provider_setting"
    refute contains_binary?(socket_assigns(missing_view), missing_secret)

    {:ok, stale_view, _html} = live(conn, "/settings/oauth")

    assert {:ok, current} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "current-client", "client_secret" => "current-secret"},
               expected_lock_version: created.lock_version
             )

    stale_secret = "stale-integer-secret-never-render"

    html =
      stale_view
      |> form("#oauth-provider-gmail-form",
        provider: "gmail",
        oauth_provider_setting: %{
          client_id: "stale-client",
          client_secret: stale_secret,
          lock_version: Integer.to_string(created.lock_version)
        }
      )
      |> render_submit()

    assert html =~ "OAuth configuration could not be saved."
    assert html =~ "current-client"
    assert html =~ ~s(value="#{current.lock_version}")
    refute html =~ stale_secret
    refute html =~ "stale_oauth_provider_setting"
    refute contains_binary?(socket_assigns(stale_view), stale_secret)
  end

  test "malformed lock versions remount without retaining the submitted secret", %{conn: conn} do
    assert {:ok, configured} = put_setting("current-client", "current-secret")
    {:ok, view, _html} = live(conn, "/settings/oauth")
    secret = "malformed-version-secret-never-render"

    _html =
      render_click(view, "save-provider", %{
        "provider" => "gmail",
        "oauth_provider_setting" => %{
          "client_id" => "attacker-client",
          "client_secret" => secret,
          "lock_version" => "not-a-version"
        }
      })

    assert_redirect(view, "/settings/oauth")

    row = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    assert row.client_id == "current-client"
    assert row.lock_version == configured.lock_version
    refute inspect(row) =~ secret
  end

  test "corrupt stored credentials show a generic configuration error", %{conn: conn} do
    assert {:ok, _view} = put_setting("corrupt-client", "corrupt-secret-never-render")
    row = Repo.get_by!(OAuthProviderSetting, provider: "gmail")

    row
    |> Ecto.Changeset.change(client_secret_ciphertext: <<1, 2, 3>>)
    |> Repo.update!()

    {:ok, view, html} = live(conn, "/settings/oauth")

    assert html =~ "Configuration error"
    assert html =~ "corrupt-client"
    assert has_element?(view, "#remove-oauth-provider-gmail")
    refute html =~ "corrupt-secret-never-render"
    refute html =~ "credential_authentication_failed"
    refute html =~ "invalid_credential_envelope"
    refute html =~ "ciphertext"
    refute contains_exact_binary?(socket_assigns(view), <<1, 2, 3>>)
  end

  test "remove is confirmed and immediately reconnects Gmail receive and send", %{conn: conn} do
    assert {:ok, configured} = put_setting("client", "secret")
    family = insert_oauth_family!("remove")

    {:ok, view, _html} = live(conn, "/settings/oauth")

    assert has_element?(
             view,
             "button#remove-oauth-provider-gmail.settings-action-error[phx-click='remove-provider'][aria-label='Remove Google OAuth configuration'][data-confirm*='Gmail receive and send will stop'][data-confirm*='reconnect']"
           )

    refute has_element?(view, "#confirm-dialog-remove-oauth-provider-gmail")

    html =
      render_click(view, "remove-provider", %{
        "provider" => "gmail",
        "lock_version" => Integer.to_string(configured.lock_version)
      })

    assert_push_event(view, "focus-oauth-provider", %{provider: "gmail"})
    assert html =~ "Not configured"
    assert html =~ "Google OAuth configuration removed."
    refute html =~ "revok"
    refute has_element?(view, "#remove-oauth-provider-gmail")
    assert is_nil(Repo.get_by(OAuthProviderSetting, provider: "gmail"))

    authorization = Repo.get!(OAuthAuthorization, family.authorization.id)
    receive = Repo.get!(ReceiveMethod, family.receive.id)
    send_method = Repo.get!(SendMethod, family.send.id)

    assert authorization.status == "reconnect_required"
    assert receive.status == "reconnect_required"
    refute receive.enabled
    refute receive.sync_enabled
    assert send_method.status == "reconnect_required"
    refute send_method.enabled
  end

  test "remove honors the rendered lock version and reloads after a stale submission", %{
    conn: conn
  } do
    assert {:ok, initial} = put_setting("initial-client", "initial-secret")
    {:ok, view, _html} = live(conn, "/settings/oauth")

    assert {:ok, current} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "current-client", "client_secret" => "current-secret"},
               expected_lock_version: initial.lock_version
             )

    html =
      render_click(view, "remove-provider", %{
        "provider" => "gmail",
        "lock_version" => Integer.to_string(initial.lock_version)
      })

    assert html =~ "OAuth configuration could not be removed."
    assert html =~ "current-client"
    assert html =~ ~s(value="#{current.lock_version}")
    refute html =~ "stale_oauth_provider_setting"
    assert Repo.get_by!(OAuthProviderSetting, provider: "gmail").client_id == "current-client"
  end

  test "unsupported provider events and help routes fail safely without creating atoms", %{
    conn: conn
  } do
    provider = "unsupported-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end

    {:ok, view, _html} = live(conn, "/settings/oauth")

    _result =
      render_click(view, "save-provider", %{
        "provider" => provider,
        "oauth_provider_setting" => %{
          "client_id" => "client",
          "client_secret" => "unsupported-secret-never-render",
          "lock_version" => ""
        }
      })

    assert_redirect(view, "/settings/oauth")
    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end

    {:ok, malformed_view, _html} = live(conn, "/settings/oauth")

    _result =
      render_click(malformed_view, "save-provider", %{
        "provider" => "gmail",
        "oauth_provider_setting" => "malformed"
      })

    assert_redirect(malformed_view, "/settings/oauth")

    {:ok, remove_view, _html} = live(conn, "/settings/oauth")

    html =
      render_click(remove_view, "remove-provider", %{
        "provider" => provider,
        "lock_version" => ""
      })

    assert html =~ "OAuth configuration could not be removed."

    assert {:error, {:live_redirect, %{to: "/settings/oauth", flash: flash}}} =
             live(conn, "/settings/oauth/#{provider}/help")

    assert flash["error"] == "OAuth provider help is unavailable."
    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end

    malformed_provider = "not valid!#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(malformed_provider) end

    assert {:error, {:live_redirect, %{to: "/settings/oauth", flash: malformed_flash}}} =
             live(conn, "/settings/oauth/#{URI.encode(malformed_provider)}/help")

    assert malformed_flash["error"] == "OAuth provider help is unavailable."
    assert_raise ArgumentError, fn -> String.to_existing_atom(malformed_provider) end
  end

  test "Gmail help renders catalog setup instructions and exact callback accessibly", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/settings/oauth/gmail/help")

    callback_uri = "http://localhost:4002/connectors/gmail/callback"

    assert html =~ ~s(data-current="oauth")
    assert has_element?(view, "h1", "Set up Google OAuth")
    assert has_element?(view, "h2", "Setup checklist")
    assert has_element?(view, "ol > li", "Create or select a Google Cloud project.")
    assert has_element?(view, "ol > li", "Enable the Gmail API.")
    assert has_element?(view, "ol > li", "Configure OAuth branding and audience.")

    assert has_element?(
             view,
             "ol > li",
             "Add only openid, email, gmail.readonly, and gmail.send."
           )

    assert has_element?(view, "ol > li", "Add test users when the app is in Testing mode.")
    assert has_element?(view, "ol > li", "Create a Web application OAuth client.")
    assert has_element?(view, "ol > li", "Register the exact callback URI shown below.")
    assert has_element?(view, "ol > li", "Copy the client ID and secret into Settings OAuth.")

    assert has_element?(
             view,
             "ol > li",
             "Complete Google verification before public use when required."
           )

    assert has_element?(view, "h2", "Callback URI")

    assert has_element?(
             view,
             "#oauth-provider-gmail-help-callback[readonly][value='#{callback_uri}']"
           )

    assert has_element?(view, "h2", "Required scopes")

    for {scope, purpose} <- [
          {"openid", "Confirm the Google account identity."},
          {"email", "Read the Google account email address."},
          {"https://www.googleapis.com/auth/gmail.readonly",
           "Receive mail by reading Gmail messages without modifying them."},
          {"https://www.googleapis.com/auth/gmail.send", "Send mail through Gmail."}
        ] do
      row = "[data-scope='#{scope}']"
      assert has_element?(view, "#{row} > dt > code", scope)
      assert has_element?(view, "#{row} > dd", purpose)
    end

    assert html =~ "Testing-mode authorizations can expire after seven days."

    assert html =~
             "Sensitive or restricted scopes may require Google verification before public use."

    assert has_element?(view, "h2", "Official Google documentation")

    for {label, href} <- [
          {"Manage app audience", "https://support.google.com/cloud/answer/15549945?hl=en"},
          {"OAuth verification", "https://support.google.com/cloud/answer/13463073?hl=en"},
          {"Request minimum scopes", "https://support.google.com/cloud/answer/13807380?hl=en"}
        ] do
      assert has_element?(
               view,
               "a[href='#{href}'][target='_blank'][rel='noopener noreferrer'][aria-label='#{label} (opens in a new tab)']",
               label
             )
    end

    assert has_element?(
             view,
             "a[href='/settings/oauth#oauth-provider-gmail']",
             "Back to Google OAuth configuration"
           )

    refute has_element?(view, "input[type='password']")
    refute html =~ "Client secret"
    refute html =~ "MANIFOLD_GMAIL_CLIENT_SECRET"
    refute html =~ "client_secret_ciphertext"
  end

  defp put_setting(client_id, client_secret) do
    Connectors.put_oauth_provider_setting("gmail", %{
      "client_id" => client_id,
      "client_secret" => client_secret
    })
  end

  defp insert_oauth_family!(suffix) do
    unique = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "#{suffix}-#{unique}.example.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "person"})
    account = Repo.preload(account, :domain)
    authorization_id = Ecto.UUID.generate()

    {:ok, access_ciphertext} =
      Crypto.encrypt("gmail-#{suffix}-access", "credential:#{authorization_id}:access")

    {:ok, refresh_ciphertext} =
      Crypto.encrypt("gmail-#{suffix}-refresh", "credential:#{authorization_id}:refresh")

    authorization =
      %OAuthAuthorization{id: authorization_id}
      |> OAuthAuthorization.changeset(%{
        account_id: account.id,
        provider: "gmail",
        provider_subject_id: "gmail-subject-#{suffix}-#{unique}",
        email_address: Accounts.account_address(account),
        granted_scopes: ["scope"],
        status: "connected",
        key_version: 1,
        access_token_ciphertext: access_ciphertext,
        refresh_token_ciphertext: refresh_ciphertext,
        token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })
      |> Repo.insert!()

    receive =
      %ReceiveMethod{}
      |> ReceiveMethod.changeset(%{
        account_id: account.id,
        oauth_authorization_id: authorization.id,
        kind: "gmail",
        provider_account_id: "gmail-subject-#{suffix}-#{unique}",
        email_address: Accounts.account_address(account),
        status: "connected",
        enabled: true,
        sync_enabled: true,
        granted_scopes: ["scope"]
      })
      |> Repo.insert!()

    send_method =
      %SendMethod{}
      |> SendMethod.changeset(%{
        account_id: account.id,
        oauth_authorization_id: authorization.id,
        kind: "gmail",
        email_address: Accounts.account_address(account),
        status: "connected",
        enabled: true
      })
      |> Repo.insert!()

    %{authorization: authorization, receive: receive, send: send_method}
  end

  defp socket_assigns(view) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
  end

  defp contains_exact_binary?(value, sentinel) when is_binary(value), do: value == sentinel

  defp contains_exact_binary?(value, sentinel) when is_struct(value),
    do: value |> Map.from_struct() |> contains_exact_binary?(sentinel)

  defp contains_exact_binary?(value, sentinel) when is_map(value),
    do:
      Enum.any?(value, fn {key, item} ->
        contains_exact_binary?(key, sentinel) or contains_exact_binary?(item, sentinel)
      end)

  defp contains_exact_binary?(value, sentinel) when is_list(value),
    do: Enum.any?(value, &contains_exact_binary?(&1, sentinel))

  defp contains_exact_binary?(value, sentinel) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_exact_binary?(sentinel)

  defp contains_exact_binary?(_value, _sentinel), do: false

  defp contains_binary?(value, sentinel) when is_binary(value),
    do: :binary.match(value, sentinel) != :nomatch

  defp contains_binary?(value, sentinel) when is_struct(value),
    do: value |> Map.from_struct() |> contains_binary?(sentinel)

  defp contains_binary?(value, sentinel) when is_map(value),
    do:
      Enum.any?(value, fn {key, item} ->
        contains_binary?(key, sentinel) or contains_binary?(item, sentinel)
      end)

  defp contains_binary?(value, sentinel) when is_list(value),
    do: Enum.any?(value, &contains_binary?(&1, sentinel))

  defp contains_binary?(value, sentinel) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_binary?(sentinel)

  defp contains_binary?(_value, _sentinel), do: false

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end
