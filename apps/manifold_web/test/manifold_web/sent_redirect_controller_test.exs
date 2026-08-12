defmodule ManifoldWeb.SentRedirectControllerTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Mail
  alias Manifold.Mail.Schema.Folder
  alias Manifold.Repo

  @unavailable "The requested mailbox view is unavailable."

  test "legacy Sent list redirects to the projected Sent folder", %{conn: conn} do
    mailbox = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    sent = Enum.find(folders, &(&1.kind == "sent"))

    response = get(conn, "/mail/#{mailbox.id}/sent")

    assert redirected_to(response, 302) == "/mail/#{mailbox.id}/folders/#{sent.id}"
  end

  test "legacy Sent detail preserves mailbox and message IDs for Send activity", %{conn: conn} do
    mailbox = mailbox_fixture()
    outbound_message_id = Ecto.UUID.generate()

    response = get(conn, "/mail/#{mailbox.id}/sent/#{outbound_message_id}")

    assert redirected_to(response, 302) ==
             "/mail/#{mailbox.id}/send-activity/#{outbound_message_id}"
  end

  test "invalid and unavailable mailbox IDs redirect safely", %{conn: conn} do
    invalid = get(conn, "/mail/not-a-uuid/sent")
    assert_unavailable(invalid)

    unavailable = get(recycle(conn), "/mail/#{Ecto.UUID.generate()}/sent")
    assert_unavailable(unavailable)
  end

  test "an unavailable projected Sent folder redirects safely", %{conn: conn} do
    mailbox = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    sent = Enum.find(folders, &(&1.kind == "sent"))

    Folder
    |> Repo.get!(sent.id)
    |> Ecto.Changeset.change(kind: "custom")
    |> Repo.update!()

    %Folder{}
    |> Folder.changeset(%{
      mailbox_id: mailbox.id,
      kind: "custom",
      name: "Sent (custom #{sent.id})"
    })
    |> Repo.insert!()

    conn
    |> get("/mail/#{mailbox.id}/sent")
    |> assert_unavailable()
  end

  test "invalid outbound message ID redirects safely", %{conn: conn} do
    mailbox = mailbox_fixture()

    conn
    |> get("/mail/#{mailbox.id}/sent/not-a-uuid")
    |> assert_unavailable()
  end

  defp assert_unavailable(conn) do
    assert redirected_to(conn, 302) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == @unavailable
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "sent-redirect#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})
    mailbox
  end
end
