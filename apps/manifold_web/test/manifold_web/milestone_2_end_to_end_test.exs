defmodule ManifoldWeb.Milestone2EndToEndTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Ingest.Jobs.{ArchiveRawEmail, EvaluateInboundSecurity, ProjectInboundMail}
  alias Manifold.Ingest.Schema.{InboundDelivery, MessageEvent}
  alias Manifold.Mail
  alias Manifold.Mail.Schema.{MailboxEntry, Message}
  alias Manifold.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_storage =
      Map.new([:spool_dir, :raw_store_dir, :blob_store_dir], fn key ->
        {key, Application.fetch_env!(:manifold_storage, key)}
      end)

    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))
    Application.put_env(:manifold_storage, :blob_store_dir, Path.join(tmp_dir, "blobs"))

    on_exit(fn ->
      Enum.each(previous_storage, fn {key, value} ->
        Application.put_env(:manifold_storage, key, value)
      end)
    end)

    :ok
  end

  test "SMTP delivery reaches searchable inbox and LiveView", %{conn: conn} do
    suffix = System.unique_integer([:positive])
    search_token = "milestone2needle#{suffix}"
    subject = "Milestone 2 end-to-end #{suffix}"

    {:ok, domain} = Accounts.create_domain(%{name: "m2-e2e-#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})
    {:ok, other_mailbox} = Accounts.create_account(domain, %{local_part: "other"})

    port = start_smtp!()
    socket = connect_smtp!(port)

    smtp_command!(socket, "EHLO integration.test\r\n", "250")
    smtp_command!(socket, "MAIL FROM:<sender@example.net>\r\n", "250")

    smtp_command!(
      socket,
      "RCPT TO:<inbox@#{domain.normalized_domain}>\r\n",
      "250"
    )

    assert ["354" <> _] = smtp_command!(socket, "DATA\r\n", "354")

    raw_message =
      [
        "From: Integration Sender <sender@example.net>",
        "To: inbox@#{domain.normalized_domain}",
        "Subject: #{subject}",
        "Message-ID: <m2-e2e-#{suffix}@example.net>",
        "Content-Type: text/plain; charset=utf-8",
        "",
        "Durable pipeline body containing #{search_token}.",
        ""
      ]
      |> Enum.join("\r\n")

    :ok = :gen_tcp.send(socket, raw_message <> ".\r\n")
    assert ["250 2.0.0 accepted as " <> ingest_id] = smtp_response!(socket)
    :ok = :gen_tcp.close(socket)

    delivery = Repo.get_by!(InboundDelivery, ingest_id: ingest_id)
    assert delivery.raw_storage_state == "spooled"
    assert delivery.processing_state == "accepted"
    assert File.exists?(Path.join(delivery.spool_bundle_path, "raw.eml"))

    assert Repo.get_by!(MessageEvent,
             inbound_delivery_id: delivery.id,
             event_type: "accepted"
           )

    archive_job =
      Repo.get_by!(Oban.Job,
        worker: inspect(ArchiveRawEmail),
        args: %{"inbound_delivery_id" => delivery.id}
      )

    assert :ok = ArchiveRawEmail.perform(archive_job)

    archived = Repo.get!(InboundDelivery, delivery.id)
    assert archived.raw_storage_state == "archived"
    assert archived.raw_object_key
    refute File.exists?(archived.spool_bundle_path)

    parser_version = Application.get_env(:manifold_mail, :parser_version, 1)
    sanitizer_version = Application.get_env(:manifold_mail, :sanitizer_version, 1)

    projection_job =
      Repo.get_by!(Oban.Job,
        worker: inspect(ProjectInboundMail),
        args: %{
          "inbound_delivery_id" => delivery.id,
          "parser_version" => parser_version,
          "sanitizer_version" => sanitizer_version
        }
      )

    assert :ok = ProjectInboundMail.perform(projection_job)

    security_job =
      Repo.get_by!(Oban.Job,
        worker: inspect(EvaluateInboundSecurity),
        args: %{"inbound_delivery_id" => delivery.id, "evaluation_version" => 1}
      )

    assert :ok = EvaluateInboundSecurity.perform(security_job)

    projected = Repo.get!(InboundDelivery, delivery.id)
    assert projected.processing_state == "processed"
    assert %Message{subject: ^subject} = Repo.get_by!(Message, inbound_delivery_id: delivery.id)

    assert %MailboxEntry{mailbox_id: mailbox_id, message_id: message_id} =
             Repo.get_by!(MailboxEntry,
               inbound_delivery_id: delivery.id,
               mailbox_id: mailbox.id
             )

    assert mailbox_id == mailbox.id
    assert message_id

    assert {:ok, %{items: [%{subject: ^subject}]}} =
             Mail.search(mailbox.id, search_token)

    assert {:ok, %{items: []}} = Mail.search(other_mailbox.id, search_token)

    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))

    assert {:ok, _view, html} =
             live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

    assert html =~ subject
    assert html =~ search_token
  end

  defp start_smtp! do
    ref = {:manifold_web_m2_e2e, System.unique_integer([:positive])}

    options = [
      domain: ~c"localhost",
      address: {127, 0, 0, 1},
      port: 0,
      sessionoptions: [
        {:allow_bare_newlines, false},
        {:callbackoptions,
         [
           max_message_bytes: 25 * 1024 * 1024,
           max_recipients: 100,
           tls_enabled?: false,
           resolver: Manifold.Accounts,
           ingest: Manifold.Ingest
         ]}
      ]
    ]

    assert {:ok, _pid} = :gen_smtp_server.start(ref, Manifold.SMTP.Session, options)
    on_exit(fn -> :gen_smtp_server.stop(ref) end)

    port = :ranch.get_port(ref)
    assert is_integer(port) and port > 0
    port
  end

  defp connect_smtp!(port) do
    assert {:ok, socket} =
             :gen_tcp.connect(
               {127, 0, 0, 1},
               port,
               [:binary, packet: :line, active: false],
               2_000
             )

    assert ["220" <> _] = smtp_response!(socket)
    socket
  end

  defp smtp_command!(socket, command, expected_code) do
    :ok = :gen_tcp.send(socket, command)
    assert [<<^expected_code::binary-size(3), _rest::binary>> | _] = smtp_response!(socket)
  end

  defp smtp_response!(socket) do
    assert {:ok, first} = :gen_tcp.recv(socket, 0, 2_000)
    code = binary_part(first, 0, 3)
    first = String.trim_trailing(first)

    if String.starts_with?(first, code <> "-") do
      collect_smtp_response!(socket, code, [first])
    else
      [first]
    end
  end

  defp collect_smtp_response!(socket, code, lines) do
    assert {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    line = String.trim_trailing(line)

    if String.starts_with?(line, code <> "-") do
      collect_smtp_response!(socket, code, [line | lines])
    else
      Enum.reverse([line | lines])
    end
  end
end
