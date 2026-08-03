defmodule ManifoldWeb.MailboxLiveTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts

  test "creates a mailbox under an existing domain", %{conn: conn} do
    {:ok, domain} = Accounts.create_domain(%{name: unique_domain("existing")})

    assert {:ok, view, _html} = live(conn, ~p"/mailboxes")
    assert has_element?(view, "#create-mailbox-button", "Create mailbox")
    refute has_element?(view, "#mailbox-setup-panel")

    view |> element("#create-mailbox-button") |> render_click()

    assert has_element?(view, "#mailbox-domain-heading", "Choose or create a domain")
    assert has_element?(view, "#mailbox-domain-selection option[value='#{domain.id}']")

    view
    |> form("#mailbox-domain-form", %{domain: %{selection: domain.id}})
    |> render_submit()

    assert has_element?(view, "#mailbox-details-heading", "Create the mailbox")
    assert has_element?(view, "#mailbox-address-domain", "@#{domain.normalized_domain}")

    html =
      view
      |> form("#create-mailbox-form", %{
        mailbox: %{local_part: "person", display_name: "Personal mail"}
      })
      |> render_submit()

    assert html =~ "person@#{domain.normalized_domain}"
    assert html =~ "Mailbox created."
    refute has_element?(view, "#mailbox-setup-panel")

    assert [mailbox] = Accounts.list_mailboxes(domain)
    assert mailbox.local_part == "person"
    assert mailbox.display_name == "Personal mail"
    assert mailbox.active
    assert mailbox.plus_addressing_enabled
  end

  test "mailbox validation stays on the details step", %{conn: conn} do
    {:ok, domain} = Accounts.create_domain(%{name: unique_domain("validation")})
    {:ok, _mailbox} = Accounts.create_mailbox(domain, %{local_part: "taken"})
    {:ok, view, _html} = live(conn, ~p"/mailboxes")

    open_existing_domain(view, domain)
    refute has_element?(view, "#mailbox-local-part[aria-invalid]")
    refute has_element?(view, "#mailbox-local-part[aria-describedby]")

    html =
      view
      |> form("#create-mailbox-form", %{mailbox: %{local_part: "bad local part"}})
      |> render_submit()

    assert html =~ "has invalid format"
    assert has_element?(view, "#mailbox-local-part-error.settings-error")

    assert has_element?(
             view,
             "#mailbox-local-part[aria-invalid='true'][aria-describedby='mailbox-local-part-error']"
           )

    html =
      view
      |> form("#create-mailbox-form", %{mailbox: %{local_part: "TAKEN"}})
      |> render_submit()

    assert html =~ "has already been taken"
    assert Accounts.list_mailboxes(domain) |> length() == 1
  end

  test "malformed mailbox payload is ignored on the details step", %{conn: conn} do
    {:ok, domain} = Accounts.create_domain(%{name: unique_domain("malformed")})
    {:ok, view, _html} = live(conn, ~p"/mailboxes")

    open_existing_domain(view, domain)

    render_hook(view, "create-mailbox", %{"mailbox" => "malformed"})

    assert has_element?(view, "#mailbox-details-heading", "Create the mailbox")
    assert Accounts.list_mailboxes(domain) == []
  end

  test "cancel closes and clears transient mailbox setup", %{conn: conn} do
    {:ok, domain} = Accounts.create_domain(%{name: unique_domain("cancel")})
    {:ok, view, _html} = live(conn, ~p"/mailboxes")

    open_existing_domain(view, domain)
    assert has_element?(view, "#mailbox-setup-panel")

    assert has_element?(
             view,
             "#cancel-mailbox-setup[phx-click*='focus'][phx-click*='#create-mailbox-button']",
             "Cancel"
           )

    view |> element("#cancel-mailbox-setup") |> render_click()

    refute has_element?(view, "#mailbox-setup-panel")

    view |> element("#create-mailbox-button") |> render_click()
    assert has_element?(view, "#mailbox-domain-heading")
    refute has_element?(view, "#mailbox-details-heading")
  end

  test "setup panel labels steps and manages focus", %{conn: conn} do
    {:ok, domain} = Accounts.create_domain(%{name: unique_domain("a11y")})
    {:ok, view, _html} = live(conn, ~p"/mailboxes")

    view |> element("#create-mailbox-button") |> render_click()

    assert has_element?(
             view,
             "#mailbox-setup-panel[aria-labelledby='mailbox-setup-title'] #mailbox-domain-heading[tabindex='-1'][phx-mounted*='focus']"
           )

    assert has_element?(
             view,
             "#cancel-mailbox-setup[phx-click*='cancel-mailbox-setup'][phx-click*='focus'][phx-click*='#create-mailbox-button']"
           )

    view
    |> form("#mailbox-domain-form", %{domain: %{selection: domain.id}})
    |> render_submit()

    assert has_element?(
             view,
             "#mailbox-details-heading[tabindex='-1'][phx-mounted*='focus']"
           )
  end

  test "creates a domain before creating the first mailbox", %{conn: conn} do
    assert Accounts.list_domains() == []
    {:ok, view, _html} = live(conn, ~p"/mailboxes")

    view |> element("#create-mailbox-button") |> render_click()

    assert has_element?(view, "#new-domain-name")
    refute has_element?(view, "#new-domain-name[aria-invalid]")
    refute has_element?(view, "#new-domain-name[aria-describedby]")
    refute has_element?(view, "#mailbox-domain-selection")

    html =
      view
      |> form("#mailbox-domain-form", %{domain: %{name: "bad domain"}})
      |> render_submit()

    assert html =~ "domain syntax is invalid"
    assert has_element?(view, "#domain-name-error.settings-error")

    assert has_element?(
             view,
             "#new-domain-name[aria-invalid='true'][aria-describedby='domain-name-error']"
           )

    view
    |> form("#mailbox-domain-form", %{domain: %{name: "New-Mail.TEST"}})
    |> render_submit()

    assert has_element?(view, "#mailbox-address-domain", "@new-mail.test")

    view
    |> form("#create-mailbox-form", %{mailbox: %{local_part: "inbox"}})
    |> render_submit()

    assert [%{normalized_domain: "new-mail.test"}] = Accounts.list_domains()
    assert [%{canonical_local_part: "inbox"}] = Accounts.list_mailboxes()
  end

  test "back after new-domain creation resets to existing domain selection", %{conn: conn} do
    assert Accounts.list_domains() == []
    {:ok, view, _html} = live(conn, ~p"/mailboxes")

    view |> element("#create-mailbox-button") |> render_click()

    view
    |> form("#mailbox-domain-form", %{domain: %{name: "Back.TEST"}})
    |> render_submit()

    assert has_element?(view, "#mailbox-details-heading")
    assert [domain] = Accounts.list_domains()

    view |> element("#back-mailbox-setup") |> render_click()

    assert has_element?(view, "#mailbox-domain-selection option[value='#{domain.id}']")
    refute has_element?(view, "#new-domain-name")

    view
    |> form("#mailbox-domain-form", %{domain: %{selection: domain.id}})
    |> render_submit()

    assert has_element?(view, "#mailbox-details-heading")
    refute render(view) =~ "has already been taken"
  end

  test "preserves the typed new-domain name across form changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mailboxes")
    view |> element("#create-mailbox-button") |> render_click()

    view
    |> form("#mailbox-domain-form", %{
      domain: %{selection: "new", name: "Draft.TEST"}
    })
    |> render_change()

    assert has_element?(view, "#new-domain-name[value='Draft.TEST']")
  end

  test "can switch from an existing domain to new-domain creation", %{conn: conn} do
    {:ok, existing} = Accounts.create_domain(%{name: unique_domain("switch")})
    {:ok, view, _html} = live(conn, ~p"/mailboxes")
    view |> element("#create-mailbox-button") |> render_click()

    view
    |> form("#mailbox-domain-form", %{domain: %{selection: "new"}})
    |> render_change()

    assert has_element?(view, "#new-domain-name")

    view
    |> form("#mailbox-domain-form", %{domain: %{name: existing.normalized_domain}})
    |> render_submit()

    assert render(view) =~ "has already been taken"
    assert has_element?(view, "#domain-name-error")
  end

  test "forged setup events cannot bypass domain selection", %{conn: conn} do
    {:ok, domain} = Accounts.create_domain(%{name: unique_domain("guard")})
    {:ok, view, _html} = live(conn, ~p"/mailboxes")

    render_hook(view, "continue-mailbox-domain", %{"domain" => %{"selection" => domain.id}})
    render_hook(view, "create-mailbox", %{"mailbox" => %{"local_part" => "forged"}})

    refute has_element?(view, "#mailbox-setup-panel")
    assert Accounts.list_mailboxes(domain) == []

    view |> element("#create-mailbox-button") |> render_click()
    render_hook(view, "continue-mailbox-domain", %{"domain" => %{"selection" => "unknown"}})

    assert has_element?(view, "#mailbox-domain-heading")
    refute has_element?(view, "#mailbox-details-heading")
  end

  test "external-account entry returns with the created mailbox", %{conn: conn} do
    {:ok, domain} = Accounts.create_domain(%{name: unique_domain("return")})

    assert {:ok, view, _html} =
             live(conn, ~p"/mailboxes?#{[source: "external_account", provider: "gmail"]}")

    open_existing_domain(view, domain)

    view
    |> form("#create-mailbox-form", %{mailbox: %{local_part: "imports"}})
    |> render_submit()

    [mailbox] = Accounts.list_mailboxes(domain)

    assert_redirect(
      view,
      ~p"/settings/accounts/new?#{[provider: "gmail", mailbox_id: mailbox.id]}"
    )
  end

  defp open_existing_domain(view, domain) do
    view |> element("#create-mailbox-button") |> render_click()

    view
    |> form("#mailbox-domain-form", %{domain: %{selection: domain.id}})
    |> render_submit()
  end

  defp unique_domain(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}.test"
  end
end
