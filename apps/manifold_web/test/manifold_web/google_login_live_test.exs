defmodule ManifoldWeb.GoogleLoginLiveTest do
  use ManifoldWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.OAuth
  alias Manifold.Connectors.Schema.OAuthTransaction
  alias Manifold.Repo

  @redirect_uri "http://localhost:4290/connectors/gmail/callback"

  setup do
    previous = Application.fetch_env!(:manifold_connectors, :providers)

    gmail =
      previous
      |> Keyword.fetch!(:gmail)
      |> Keyword.put(:req_options, plug: {Req.Test, __MODULE__})

    Application.put_env(:manifold_connectors, :providers, Keyword.put(previous, :gmail, gmail))
    on_exit(fn -> Application.put_env(:manifold_connectors, :providers, previous) end)

    {:ok, account} =
      Accounts.create_account(%{name: "Google login", address: "google@example.test"})

    {:ok, setting} =
      Connectors.put_oauth_provider_setting("gmail", %{
        client_id: "google-client",
        client_secret: "google-secret",
        callback_url: @redirect_uri
      })

    {:ok, account: account, setting: setting}
  end

  for purpose <- ["receive", "send"] do
    @purpose purpose
    test "pasted Google redirect completes #{@purpose} through real token and identity adapters",
         %{
           conn: conn,
           account: account
         } do
      purpose = @purpose
      owner = self()
      stub_google(owner, purpose)

      {:ok, view, _html} =
        live(conn, "/settings/accounts/#{account.id}/google/login?purpose=#{purpose}")

      Req.Test.allow(__MODULE__, owner, view.pid)
      assert Repo.all(OAuthTransaction) == []

      view |> element("#start-google-login") |> render_click()
      query = login_query(view)
      assert query["redirect_uri"] == @redirect_uri
      assert has_element?(view, "#google-login-link[target='_blank'][rel='noopener noreferrer']")
      assert Repo.aggregate(OAuthTransaction, :count) == 1

      submit_callback(view, response_url(query))
      assert_redirect(view, "/settings/accounts/#{account.id}", 5_000)
      assert_received {:token_exchange, form}
      assert form["redirect_uri"] == @redirect_uri
      assert form["code"] == "private-code-sentinel"

      challenge =
        :crypto.hash(:sha256, form["code_verifier"]) |> Base.url_encode64(padding: false)

      assert challenge == query["code_challenge"]
      assert Repo.one!(OAuthTransaction).consumed_at

      methods =
        if purpose == "receive",
          do: Connectors.list_receive_methods_for_account(account.id),
          else: Connectors.list_send_methods_for_account(account.id)

      assert [%{kind: "gmail", status: "connected", enabled: true}] = methods
    end
  end

  test "malformed or unrelated callback never reaches the provider and is cleared from HTML", %{
    conn: conn,
    account: account
  } do
    {:ok, view, _html} = live(conn, "/settings/accounts/#{account.id}/google/login")
    view |> element("#start-google-login") |> render_click()
    query = login_query(view)

    for url <- [
          "not a URL",
          "https://wrong.example/callback?code=private-code-sentinel&state=#{query["state"]}",
          "#{@redirect_uri}?code=private-code-sentinel&state=wrong-state",
          "#{@redirect_uri}?error=access_denied&state=#{query["state"]}"
        ] do
      html = submit_callback(view, url)
      assert html =~ "does not match a valid Google login"
      refute html =~ "private-code-sentinel"
      assert has_element?(view, "#google-callback-response[value='']")
      assert Repo.one!(OAuthTransaction).consumed_at == nil
    end
  end

  test "callback submission logs redact the full URL and authorization code", %{
    conn: conn,
    account: account
  } do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    {:ok, view, _html} = live(conn, "/settings/accounts/#{account.id}/google/login")
    view |> element("#start-google-login") |> render_click()
    url = @redirect_uri <> "?code=private-code-sentinel&state=wrong-state"

    log = capture_log([level: :debug], fn -> submit_callback(view, url) end)
    assert log =~ "HANDLE EVENT"
    assert log =~ "[FILTERED]"
    refute log =~ "private-code-sentinel"
    refute log =~ url
  end

  test "expired and rotated attempts require a fresh login", %{
    conn: conn,
    account: account,
    setting: setting
  } do
    {:ok, view, _html} = live(conn, "/settings/accounts/#{account.id}/google/login")
    view |> element("#start-google-login") |> render_click()
    query = login_query(view)

    Repo.update_all(OAuthTransaction,
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert submit_callback(view, response_url(query)) =~ "does not match a valid Google login"

    view |> element("#start-google-login") |> render_click()
    new_query = login_query(view)
    refute query["state"] == new_query["state"]

    assert {:ok, _} =
             Connectors.put_oauth_provider_setting("gmail", %{client_secret: "rotated-secret"},
               expected_lock_version: setting.lock_version
             )

    assert submit_callback(view, response_url(new_query)) =~ "does not match a valid Google login"
    assert Connectors.list_receive_methods_for_account(account.id) == []
  end

  test "failed token exchange logs a safe reason without callback or provider secrets", %{
    conn: conn,
    account: account
  } do
    Req.Test.stub(__MODULE__, fn request ->
      request
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        error: "invalid_grant",
        error_description: "private-provider-description-sentinel"
      })
    end)

    {:ok, view, _html} = live(conn, "/settings/accounts/#{account.id}/google/login")
    Req.Test.allow(__MODULE__, self(), view.pid)
    view |> element("#start-google-login") |> render_click()
    query = login_query(view)
    url = response_url(query)

    log =
      capture_log(fn ->
        submit_callback(view, url)
        html = render_async(view)
        assert html =~ "Google login could not be completed."
        refute html =~ "private-provider-description-sentinel"
      end)

    assert log =~ "invalid_grant"
    refute log =~ url
    refute log =~ "private-code-sentinel"
    refute log =~ query["state"]
    refute log =~ "private-provider-description-sentinel"
    assert Repo.one!(OAuthTransaction).consumed_at
    assert Connectors.list_receive_methods_for_account(account.id) == []
  end

  test "another attempt cannot be submitted on this login page", %{conn: conn, account: account} do
    {:ok, view, _html} = live(conn, "/settings/accounts/#{account.id}/google/login")
    view |> element("#start-google-login") |> render_click()
    {:ok, unrelated} = OAuth.start("gmail", account.id, @redirect_uri)

    url =
      @redirect_uri <>
        "?" <> URI.encode_query(%{code: "private-code-sentinel", state: unrelated.state})

    assert submit_callback(view, url) =~ "does not match a valid Google login"
    assert Repo.all(from(t in OAuthTransaction, select: t.consumed_at)) == [nil, nil]
  end

  test "invalid account, inactive account and purpose cannot open login", %{
    conn: conn,
    account: account
  } do
    for path <- [
          "/settings/accounts/not-a-uuid/google/login",
          "/settings/accounts/#{account.id}/google/login?purpose=invalid"
        ] do
      assert {:error, {:live_redirect, %{to: "/settings/accounts"}}} = live(conn, path)
    end

    Repo.update!(Ecto.Changeset.change(account, active: false))

    assert {:error, {:live_redirect, %{to: "/settings/accounts"}}} =
             live(conn, "/settings/accounts/#{account.id}/google/login")

    assert Repo.all(OAuthTransaction) == []
  end

  defp login_query(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#google-login-link")
    |> LazyHTML.attribute("href")
    |> hd()
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
  end

  defp response_url(query),
    do:
      @redirect_uri <>
        "?" <>
        URI.encode_query(%{
          iss: "https://accounts.google.com",
          code: "private-code-sentinel",
          state: query["state"],
          scope: query["scope"],
          authuser: "0",
          prompt: "consent"
        })

  defp submit_callback(view, url) do
    view
    |> form("#google-callback-form", oauth_callback: %{callback_response_url: url})
    |> render_submit()
  end

  defp stub_google(owner, purpose) do
    Req.Test.stub(__MODULE__, fn request ->
      case request.request_path do
        "/token" ->
          {:ok, body, request} = Plug.Conn.read_body(request)
          send(owner, {:token_exchange, URI.decode_query(body)})

          scope =
            if purpose == "receive",
              do: "https://www.googleapis.com/auth/gmail.readonly",
              else: "https://www.googleapis.com/auth/gmail.send"

          Req.Test.json(request, %{
            access_token: "private-access-token",
            refresh_token: "private-refresh-token",
            expires_in: 3600,
            scope: "openid email " <> scope,
            token_type: "Bearer"
          })

        "/v1/userinfo" ->
          Req.Test.json(request, %{sub: "google-subject", email: "google@example.test"})

        "/gmail/v1/users/me/profile" ->
          Req.Test.json(request, %{historyId: "100"})
      end
    end)
  end
end
