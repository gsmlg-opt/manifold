defmodule ManifoldWeb.OutboundMailLiveTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, MicrosoftScopes}
  alias Manifold.Connectors.Schema.{OAuthAuthorization, SendMethod}
  alias Manifold.Ingest.Schema.InboundDelivery
  alias Manifold.Mail
  alias Manifold.Mail.Schema.{MailboxEntry, Message, MessageAddress}
  alias Manifold.Outbound
  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Schema.ProviderSubmission
  alias Manifold.Repo

  @unavailable "The requested mailbox view is unavailable."

  defmodule MicrosoftAcceptProvider do
    @behaviour Manifold.Outbound.Provider

    alias Manifold.Outbound.Provider

    @impl true
    def submit(config, %Provider.Request{provider: "microsoft"} = request) do
      send(Keyword.fetch!(config, :test_pid), {:microsoft_submit, request})

      {:ok,
       %Provider.Submission{
         provider_message_id: nil,
         metadata: %{
           "request_id" => "graph-request-accepted",
           "client_request_id" => "graph-client-accepted"
         }
       }}
    end
  end

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

    assert [activity] = Outbound.list_send_activity(mailbox.id)
    assert activity.state == "queued"

    activity_path = "/mail/#{mailbox.id}/send-activity/#{activity.id}"
    assert_live_redirect(view, activity_path)
    assert Outbound.list_drafts(mailbox.id) == []

    assert {:ok, activity_list, list_html} =
             live(recycle(conn), "/mail/#{mailbox.id}/send-activity")

    assert list_html =~ "Persisted draft"
    assert list_html =~ "Queued"
    assert has_element?(activity_list, "section[aria-label='Send activity'] h1", "Send activity")

    assert {:ok, activity_detail, detail_html} = live(recycle(conn), activity_path)
    assert detail_html =~ "Persisted draft"
    assert detail_html =~ "Queued"

    assert has_element?(
             activity_detail,
             "article[aria-label='Send activity detail']",
             "Persisted draft"
           )
  end

  test "send-only Microsoft acceptance stays out of projected Sent", %{conn: conn} do
    mailbox = mailbox_fixture()
    method = add_microsoft_send_method(mailbox)
    assert Connectors.list_receive_methods_for_account(mailbox.id) == []

    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    sent_folder = Enum.find(folders, &(&1.kind == "sent"))

    assert {:ok, draft} =
             Outbound.create_draft(mailbox.id, %{
               subject: "Accepted by Microsoft only",
               text_body: "Waiting for authoritative projection",
               recipients: [%{kind: "to", address: "person@example.net"}]
             })

    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)

    assert :ok =
             Outbound.submit_message(queued.id,
               provider: MicrosoftAcceptProvider,
               provider_config: [test_pid: self()]
             )

    assert_receive {:microsoft_submit,
                    %Provider.Request{
                      provider: "microsoft",
                      send_method_id: send_method_id
                    }}

    assert send_method_id == method.id

    assert %ProviderSubmission{
             state: "accepted",
             provider_message_id: nil,
             provider_metadata: %{
               "request_id" => "graph-request-accepted",
               "client_request_id" => "graph-client-accepted"
             }
           } = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)

    assert {:ok, activity_view, activity_html} =
             live(conn, "/mail/#{mailbox.id}/send-activity/#{queued.id}")

    assert activity_html =~ "Accepted by Microsoft only"
    assert has_element?(activity_view, ".delivery-status", "Provider accepted")

    assert {:ok, %{items: []}} = Mail.list_conversations(mailbox.id, sent_folder.id)

    assert {:ok, sent_view, sent_html} =
             live(recycle(conn), "/mail/#{mailbox.id}/folders/#{sent_folder.id}")

    refute sent_html =~ "Accepted by Microsoft only"
    assert has_element?(sent_view, ".empty-folder", "No messages in this folder")
  end

  test "malformed Send activity detail redirects safely", %{conn: conn} do
    mailbox = mailbox_fixture()

    assert {:error, {_kind, %{to: "/", flash: flash}}} =
             live(conn, "/mail/#{mailbox.id}/send-activity/not-a-uuid")

    assert flash["error"] == @unavailable
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
    assert Outbound.list_send_activity(mailbox.id) == []
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

  defp add_microsoft_send_method(mailbox) do
    address = "#{mailbox.local_part}@#{mailbox.domain.normalized_domain}"

    authorization_id = Ecto.UUID.generate()

    assert {:ok, access} =
             Crypto.encrypt(
               "microsoft-web-access-token",
               "credential:#{authorization_id}:access"
             )

    assert {:ok, refresh} =
             Crypto.encrypt(
               "microsoft-web-refresh-token",
               "credential:#{authorization_id}:refresh"
             )

    authorization =
      %OAuthAuthorization{id: authorization_id}
      |> OAuthAuthorization.changeset(%{
        account_id: mailbox.id,
        provider: "microsoft",
        provider_subject_id: "subject-#{authorization_id}",
        email_address: address,
        granted_scopes: [MicrosoftScopes.send()],
        status: "connected",
        key_version: 1,
        access_token_ciphertext: access,
        refresh_token_ciphertext: refresh,
        token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })
      |> Repo.insert!()

    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: mailbox.id,
      oauth_authorization_id: authorization.id,
      kind: "microsoft",
      email_address: address,
      status: "connected",
      enabled: true
    })
    |> Repo.insert!()
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
