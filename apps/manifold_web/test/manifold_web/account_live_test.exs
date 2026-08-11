defmodule ManifoldWeb.AccountLiveTest do
  use ManifoldWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Manifold.AccountLifecycle.Jobs.PurgeAccount
  alias Manifold.AccountLifecycle.Schema.AccountPurge
  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Repo

  setup do
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})
    :ok
  end

  test "create account from name and address", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/accounts/new")

    {:ok, _show_view, html} =
      view
      |> form("#account-form", account: %{name: "Alice", address: "alice@example.test"})
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "Alice"
    assert html =~ "alice@example.test"

    [account] = Accounts.list_accounts()
    assert account.name == "Alice"
    assert Accounts.account_address(account) == "alice@example.test"
  end

  test "account show lists receive methods and can remove one", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Bob", address: "bob@example.test"})

    {:ok, method} =
      Connectors.create_placeholder_receive_method(account.id, "pop3")

    {:ok, show_view, html} = live(conn, ~p"/settings/accounts/#{account.id}")
    assert html =~ "bob@example.test"
    assert html =~ ~p"/settings/accounts/#{account.id}/receive_methods/new"
    assert html =~ ~p"/settings/accounts/#{account.id}/send_methods/new"
    assert html =~ "POP3"
    assert html =~ "No send methods configured."

    {:ok, new_view, html} =
      show_view
      |> element("#add-receive-method")
      |> render_click()
      |> follow_redirect(conn, ~p"/settings/accounts/#{account.id}/receive_methods/new")

    refute html =~ ~s(phx-value-kind="pop3")
    refute html =~ ~s(phx-value-kind="ews")
    assert html =~ ~s(phx-value-kind="imap")
    assert html =~ ~s(phx-value-kind="eas")

    {:ok, show_view, html} =
      new_view
      |> element("a", "Cancel")
      |> render_click()
      |> follow_redirect(conn, ~p"/settings/accounts/#{account.id}")

    assert html =~ "POP3"

    show_view
    |> element("#receive-method-#{method.id} button[phx-click=remove]")
    |> render_click()

    assert Connectors.list_receive_methods_for_account(account.id) == []
    refute render(show_view) =~ "POP3"
  end

  test "account show can add smtp send method", %{conn: conn} do
    previous_transport = Application.get_env(:manifold_connectors, :smtp_transport)
    previous_fake = Application.get_env(:manifold_connectors, :smtp_fake)

    Application.put_env(:manifold_connectors, :smtp_transport, Manifold.Connectors.SMTP.Fake)
    Application.put_env(:manifold_connectors, :smtp_fake, %{password_expected: "secret"})

    on_exit(fn ->
      restore_smtp_env(:smtp_transport, previous_transport)
      restore_smtp_env(:smtp_fake, previous_fake)
    end)

    {:ok, account} =
      Accounts.create_account(%{name: "Eve", address: "eve@example.test"})

    {:ok, show_view, _html} = live(conn, ~p"/settings/accounts/#{account.id}")

    {:ok, new_view, html} =
      show_view
      |> element("#add-send-method")
      |> render_click()
      |> follow_redirect(conn, ~p"/settings/accounts/#{account.id}/send_methods/new")

    assert html =~ "SMTP settings"

    html =
      new_view
      |> form("#smtp-send-method-form",
        smtp: %{
          email_address: "eve@example.test",
          host: "smtp.example",
          port: "465",
          tls_mode: "tls",
          username: "eve@example.test",
          password: "secret"
        }
      )
      |> render_submit()

    assert html =~ "Saving"
    assert_redirect(new_view, ~p"/settings/accounts/#{account.id}")

    {:ok, _show_view, html} = live(conn, ~p"/settings/accounts/#{account.id}")
    assert html =~ "SMTP"
    assert html =~ "eve@example.test"

    [method] = Connectors.list_send_methods_for_account(account.id)
    assert method.kind == "smtp"
    assert method.enabled
  end

  test "accounts index shows created account", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Carol", address: "carol@example.test"})

    {:ok, _view, html} = live(conn, ~p"/settings/accounts")
    assert html =~ "Carol"
    assert html =~ "carol@example.test"
    assert html =~ ~p"/settings/accounts/#{account.id}"
    assert html =~ ~p"/settings/accounts/#{account.id}/edit"
  end

  test "accounts index renders accessible icon-only account actions", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Action account", address: "actions@example.test"})

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")

    assert_icon_action(
      view,
      account.id,
      "edit-account",
      "Edit account",
      "pencil-outline"
    )

    assert_icon_action(
      view,
      account.id,
      "manage-account",
      "Manage account",
      "cog-outline"
    )

    assert_icon_action(
      view,
      account.id,
      "disable-account",
      "Disable account",
      "account-off-outline"
    )

    assert_icon_action(
      view,
      account.id,
      "delete-account",
      "Delete account",
      "delete-outline"
    )

    refute has_element?(view, "#edit-account-#{account.id}", "Edit")
    refute has_element?(view, "#manage-account-#{account.id}", "Manage")
  end

  test "disable keeps the local account and removes only the disable action", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Disabled account", address: "disabled@example.test"})

    {:ok, method} = Connectors.create_placeholder_receive_method(account.id, "pop3")
    {:ok, view, _html} = live(conn, ~p"/settings/accounts")

    view
    |> element("#disable-account-#{account.id}")
    |> render_click()

    assert has_element?(view, "#account-#{account.id}", "Disabled")
    refute has_element?(view, "#disable-account-#{account.id}")
    assert has_element?(view, "#edit-account-#{account.id}")
    assert has_element?(view, "#manage-account-#{account.id}")
    assert has_element?(view, "#delete-account-#{account.id}")
    assert Accounts.get_account!(account.id).active == false

    assert Enum.any?(
             Connectors.list_receive_methods_for_account(account.id),
             &(&1.id == method.id)
           )

    assert is_nil(socket_assign(view, :refresh_timer))
  end

  test "delete requires the exact fresh address and queues local-only deletion", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Archive Relay", address: "delete@example.test"})

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")

    view
    |> element("#delete-account-#{account.id}")
    |> render_click()

    assert has_element?(
             view,
             "#delete-account-dialog[role='dialog'][aria-modal='true'][aria-labelledby='delete-account-title'][aria-describedby='delete-account-warning']"
           )

    assert has_element?(view, "#delete-account-title", "Delete account?")
    assert has_element?(view, ".account-delete-identity strong", "Archive Relay")
    assert has_element?(view, ".account-delete-identity span", "delete@example.test")

    assert has_element?(
             view,
             "#delete-account-warning",
             "permanently deletes this account's local methods"
           )

    assert has_element?(
             view,
             "#delete-account-warning",
             "Mail and accounts held by the remote provider are not deleted"
           )

    assert {:ok, _updated} =
             Accounts.update_account(account, %{
               name: "Archive Relay",
               address: "renamed@example.test"
             })

    view
    |> form("#delete-account-form", confirmation: "delete@example.test")
    |> render_submit()

    assert has_element?(view, "#delete-account-error[role='alert']", "address does not match")
    assert has_element?(view, ".account-delete-identity strong", "Archive Relay")
    assert has_element?(view, ".account-delete-identity span", "renamed@example.test")
    assert is_nil(Repo.get_by(AccountPurge, mailbox_id: account.id))
    assert purge_jobs_for_mailbox(account.id) == []

    view
    |> form("#delete-account-form", confirmation: "renamed@example.test")
    |> render_change()

    assert has_element?(view, "#confirm-delete-account:not([disabled])")

    view
    |> form("#delete-account-form", confirmation: "renamed@example.test")
    |> render_submit()

    purge = Repo.get_by!(AccountPurge, mailbox_id: account.id)
    assert has_element?(view, "#account-#{account.id} [aria-live='polite']", "Deleting...")
    refute has_element?(view, "#account-#{account.id} .account-actions")
    assert render(view) =~ "Account deletion queued."
    assert [%Oban.Job{}] = purge_jobs(purge.id)
    assert is_reference(socket_assign(view, :refresh_timer))
  end

  test "stale retry reloads requested state and starts polling", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Stale retry", address: "stale-retry@example.test"})

    {:ok, purge} =
      Manifold.AccountLifecycle.request_deletion(account.id, "stale-retry@example.test")

    discard_purge_jobs(purge.id)

    purge
    |> AccountPurge.changeset(%{status: "failed"})
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")
    assert has_element?(view, "#retry-delete-account-#{account.id}")
    assert is_nil(socket_assign(view, :refresh_timer))

    assert {:ok, _requested} = Manifold.AccountLifecycle.retry_deletion(purge.id)

    view
    |> element("#retry-delete-account-#{account.id}")
    |> render_click()

    assert has_element?(view, "#account-#{account.id} [aria-live='polite']", "Deleting...")
    assert is_reference(socket_assign(view, :refresh_timer))
  end

  test "event reload cancels polling when no account is deleting", %{conn: conn} do
    {:ok, deleting_account} =
      Accounts.create_account(%{name: "Deleting", address: "deleting@example.test"})

    {:ok, active_account} =
      Accounts.create_account(%{name: "Still active", address: "active@example.test"})

    {:ok, purge} =
      Manifold.AccountLifecycle.request_deletion(
        deleting_account.id,
        "deleting@example.test"
      )

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")
    timer = socket_assign(view, :refresh_timer)
    assert is_reference(timer)

    discard_purge_jobs(purge.id)

    purge
    |> AccountPurge.changeset(%{status: "failed"})
    |> Repo.update!()

    view
    |> element("#disable-account-#{active_account.id}")
    |> render_click()

    assert has_element?(view, "#account-#{deleting_account.id}", "Delete failed")
    assert is_nil(socket_assign(view, :refresh_timer))
    assert Process.read_timer(timer) == false
    refute :refresh_accounts in process_messages(view.pid)
  end

  test "failed deletion exposes an accessible retry action without polling", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Failed account", address: "failed@example.test"})

    {:ok, purge} =
      Manifold.AccountLifecycle.request_deletion(account.id, "failed@example.test")

    discard_purge_jobs(purge.id)

    purge
    |> AccountPurge.changeset(%{
      status: "failed",
      error_class: "temporary",
      error_code: "storage_unavailable",
      error_message: "Local cleanup could not finish"
    })
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")

    assert has_element?(view, "#account-#{account.id}", "Delete failed")

    assert_icon_action(
      view,
      account.id,
      "retry-delete-account",
      "Retry account deletion",
      "restart"
    )

    assert is_nil(socket_assign(view, :refresh_timer))

    view
    |> element("#retry-delete-account-#{account.id}")
    |> render_click()

    assert has_element?(view, "#account-#{account.id} [aria-live='polite']", "Deleting...")
    refute has_element?(view, "#retry-delete-account-#{account.id}")
    assert is_reference(socket_assign(view, :refresh_timer))
  end

  test "refresh removes an account row after purge completion deletes the mailbox", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Gone account", address: "gone@example.test"})

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")
    assert has_element?(view, "#account-#{account.id}")

    Repo.delete!(Accounts.get_account!(account.id))
    send(view.pid, :refresh_accounts)

    refute has_element?(view, "#account-#{account.id}")
    assert is_nil(socket_assign(view, :refresh_timer))
  end

  test "accounts index and show render settings nav with Accounts current", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Nav", address: "nav@example.test"})

    {:ok, _view, html} = live(conn, ~p"/settings/accounts")
    assert html =~ ~s(id="settings-nav")
    assert html =~ ~s(data-current="accounts")

    {:ok, _view, html} = live(conn, ~p"/settings/accounts/#{account.id}")
    assert html =~ ~s(id="settings-nav")
    assert html =~ ~s(data-current="accounts")
  end

  test "edit account updates name and address", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Dana", address: "dana@example.test"})

    {:ok, view, html} = live(conn, ~p"/settings/accounts/#{account.id}/edit")
    assert html =~ "dana@example.test"

    {:ok, _show_view, html} =
      view
      |> form("#account-form", account: %{name: "Danielle", address: "danielle@example.test"})
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "Danielle"
    assert html =~ "danielle@example.test"

    updated = Accounts.get_account!(account.id)
    assert updated.name == "Danielle"
    assert Accounts.account_address(updated) == "danielle@example.test"
  end

  defp restore_smtp_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_smtp_env(key, value), do: Application.put_env(:manifold_connectors, key, value)

  defp assert_icon_action(view, account_id, action, label, icon) do
    tooltip_id = "#{action}-tooltip-#{account_id}"
    action_id = "#{action}-#{account_id}"

    assert has_element?(
             view,
             "##{tooltip_id}[aria-describedby='#{tooltip_id}-tooltip'] ##{action_id}[aria-label='#{label}'] svg[data-icon='#{icon}']"
           )

    assert has_element?(
             view,
             "##{tooltip_id} .tooltip-content[role='tooltip']",
             label
           )
  end

  defp socket_assign(view, key) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(key)
  end

  defp process_messages(pid) do
    pid
    |> Process.info(:messages)
    |> elem(1)
  end

  defp purge_jobs_for_mailbox(mailbox_id) do
    case Repo.get_by(AccountPurge, mailbox_id: mailbox_id) do
      nil -> []
      purge -> purge_jobs(purge.id)
    end
  end

  defp purge_jobs(purge_id) do
    PurgeAccount
    |> purge_job_query(purge_id)
    |> Repo.all()
  end

  defp discard_purge_jobs(purge_id) do
    PurgeAccount
    |> purge_job_query(purge_id)
    |> Repo.update_all(set: [state: "discarded"])
  end

  defp purge_job_query(worker, purge_id) do
    from(job in Oban.Job,
      where:
        job.worker == ^inspect(worker) and
          fragment("?->>'purge_id'", job.args) == ^purge_id
    )
  end
end
