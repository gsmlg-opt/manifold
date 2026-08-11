defmodule ManifoldWeb.OutboundMailLiveTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Ingest.Schema.InboundDelivery
  alias Manifold.Mail.Schema.{MailboxEntry, Message, MessageAddress}
  alias Manifold.Outbound
  alias Manifold.Repo

  test "compose creates one persisted draft and opens its editor", %{conn: conn} do
    mailbox = mailbox_fixture()
    assert {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#compose-button")
    |> render_click()

    assert [draft] = Outbound.list_drafts(mailbox.id)
    assert_live_redirect(view, ~p"/mail/#{mailbox.id}/drafts/#{draft.id}/edit")

    assert {:ok, _editor, html} =
             live(conn, ~p"/mail/#{mailbox.id}/drafts/#{draft.id}/edit")

    assert html =~ "New message"
    assert html =~ "inbox@#{mailbox.domain.normalized_domain}"
  end

  test "draft edits survive reconnect and send queues exactly once", %{conn: conn} do
    mailbox = mailbox_fixture()
    add_smtp_method(mailbox)
    {:ok, draft} = Outbound.create_draft(mailbox.id, %{})
    path = ~p"/mail/#{mailbox.id}/drafts/#{draft.id}/edit"
    assert {:ok, view, _html} = live(conn, path)

    draft_params = %{
      "draft" => %{
        "to" => "person@example.net",
        "cc" => "",
        "bcc" => "",
        "subject" => "Persisted draft",
        "text_body" => "Saved body"
      }
    }

    view
    |> form("#outbound-draft-form", draft_params)
    |> render_change()

    html =
      view
      |> element("button[phx-click=save-current-draft]")
      |> render_click()

    assert html =~ "Persisted draft"

    assert {:ok, _reconnected, html} = live(recycle(conn), path)
    assert html =~ "Persisted draft"
    assert html =~ "Saved body"

    view
    |> form("#outbound-draft-form", draft_params)
    |> render_submit()

    assert [sent] = Outbound.list_sent(mailbox.id)
    assert sent.state == "queued"
    assert_live_redirect(view, ~p"/mail/#{mailbox.id}/sent/#{sent.id}")
    assert Outbound.list_drafts(mailbox.id) == []
  end

  test "draft routes are mailbox scoped", %{conn: conn} do
    mailbox = mailbox_fixture()
    other = mailbox_fixture()
    {:ok, draft} = Outbound.create_draft(mailbox.id, %{})

    assert {:error, {_kind, %{to: "/"}}} =
             live(conn, ~p"/mail/#{other.id}/drafts/#{draft.id}/edit")
  end

  test "invalid recipients remain visible and cannot queue", %{conn: conn} do
    mailbox = mailbox_fixture()
    {:ok, draft} = Outbound.create_draft(mailbox.id, %{})
    assert {:ok, view, _html} = live(conn, ~p"/mail/#{mailbox.id}/drafts/#{draft.id}/edit")

    html =
      view
      |> form("#outbound-draft-form", %{
        "draft" => %{
          "to" => "invalid-address",
          "cc" => "",
          "bcc" => "",
          "subject" => "Cannot send",
          "text_body" => "Body"
        }
      })
      |> render_submit()

    assert html =~ "invalid-address"
    assert [_draft] = Outbound.list_drafts(mailbox.id)
    assert Outbound.list_sent(mailbox.id) == []
  end

  test "missing send method preserves the saved draft and links account setup", %{conn: conn} do
    mailbox = mailbox_fixture()
    {:ok, draft} = Outbound.create_draft(mailbox.id, %{})
    assert {:ok, view, _html} = live(conn, ~p"/mail/#{mailbox.id}/drafts/#{draft.id}/edit")

    html =
      view
      |> form("#outbound-draft-form", %{
        "draft" => %{
          "to" => "person@example.net",
          "cc" => "",
          "bcc" => "",
          "subject" => "Needs a method",
          "text_body" => "Saved before setup"
        }
      })
      |> render_submit()

    assert html =~ "Add send method"

    assert has_element?(
             view,
             ~s|a[href="/settings/accounts/#{mailbox.id}/send_methods/new"]|,
             "Add send method"
           )

    saved = Repo.get!(Manifold.Outbound.Schema.OutboundMessage, draft.id)
    assert saved.state == "draft"
    assert saved.subject == "Needs a method"
    assert saved.text_body == "Saved before setup"
    refute_redirected(view)
  end

  test "reply-all and forward drafts use the mailbox-scoped reply source" do
    mailbox = mailbox_fixture()
    message = reply_source_fixture(mailbox)

    assert {:ok, reply} = Outbound.prepare_draft(mailbox.id, message.id, :reply_all)
    assert {:ok, reply} = Outbound.get_draft(mailbox.id, reply.id)
    assert reply.subject == "Re: Project update"
    assert reply.in_reply_to == "<source@example.net>"

    assert Enum.map(reply.recipients, &{&1.kind, &1.canonical_address}) == [
             {"to", "sender@example.net"},
             {"cc", "copy@example.net"}
           ]

    assert {:ok, forward} = Outbound.prepare_draft(mailbox.id, message.id, :forward)
    assert {:ok, forward} = Outbound.get_draft(mailbox.id, forward.id)
    assert forward.subject == "Fwd: Project update"
    assert forward.recipients == []
    assert forward.text_body =~ "Forwarded message"
  end

  defp assert_live_redirect(view, path) do
    assert {^path, _flash} = assert_redirect(view)
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "compose#{suffix}.test"})

    {:ok, mailbox} =
      Accounts.create_account(domain, %{local_part: "inbox", name: "Local Inbox"})

    %{mailbox | domain: domain}
  end

  defp add_smtp_method(mailbox) do
    address = "#{mailbox.local_part}@#{mailbox.domain.normalized_domain}"

    assert {:ok, _method} =
             Connectors.create_smtp_send_method(%{
               account_id: mailbox.id,
               email_address: address,
               host: "smtp.example.test",
               port: 465,
               tls_mode: "tls",
               username: address,
               password: "secret",
               skip_test: true
             })
  end

  defp reply_source_fixture(mailbox) do
    now = DateTime.utc_now()
    delivery_id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()

    Repo.insert_all(InboundDelivery, [
      %{
        id: delivery_id,
        ingest_id: Ecto.UUID.generate(),
        peer_ip: "127.0.0.1",
        envelope_from: "sender@example.net",
        received_at: now,
        raw_size: 1,
        raw_sha256: String.duplicate("0", 64),
        spool_bundle_path: "/removed",
        raw_storage_state: "archived",
        processing_state: "processed",
        storage_domain_id: mailbox.domain_id,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all(Message, [
      %{
        id: message_id,
        inbound_delivery_id: delivery_id,
        rfc_message_id: "<source@example.net>",
        references: ["<earlier@example.net>"],
        subject: "Project update",
        sender_name: "Sender",
        sender_address: "sender@example.net",
        sent_at: now,
        text_body: "Source body",
        parser_version: 1,
        sanitizer_version: 1,
        parse_state: "parsed",
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all(MailboxEntry, [
      %{
        id: Ecto.UUID.generate(),
        mailbox_id: mailbox.id,
        inbound_delivery_id: delivery_id,
        message_id: message_id,
        original_recipient: "inbox@#{mailbox.domain.normalized_domain}",
        quarantined: false,
        inserted_at: now,
        updated_at: now
      }
    ])

    address_rows =
      [
        {"from", 0, "Sender", "sender@example.net"},
        {"to", 0, nil, "inbox@#{mailbox.domain.normalized_domain}"},
        {"cc", 0, nil, "copy@example.net"}
      ]
      |> Enum.map(fn {kind, position, display_name, address} ->
        %{
          id: Ecto.UUID.generate(),
          message_id: message_id,
          kind: kind,
          position: position,
          display_name: display_name,
          address: address,
          canonical_address: String.downcase(address, :ascii),
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(MessageAddress, address_rows)
    Repo.get!(Message, message_id)
  end
end
