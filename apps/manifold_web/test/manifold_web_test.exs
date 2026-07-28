defmodule ManifoldWebTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Ingest
  alias Manifold.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    old_spool = Application.fetch_env!(:manifold_storage, :spool_dir)
    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)

    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))

    on_exit(fn ->
      Application.put_env(:manifold_storage, :spool_dir, old_spool)
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
    end)

    :ok
  end

  test "unauthenticated access is rejected", %{conn: conn} do
    conn = get(conn, ~p"/deliveries")
    assert redirected_to(conn) == ~p"/login"
  end

  test "authenticated owner can view domain, mailbox, and delivery lists", %{conn: conn} do
    owner = owner_fixture()
    %{domain: domain} = mailbox_fixture()
    conn = log_in_owner(conn, owner)

    assert {:ok, _view, html} = live(conn, ~p"/domains")
    assert html =~ domain.normalized_domain

    assert {:ok, _view, html} = live(conn, ~p"/mailboxes")
    assert html =~ "inbox@#{domain.normalized_domain}"

    assert {:ok, _delivery} = delivery_fixture(domain)
    assert {:ok, _view, html} = live(conn, ~p"/deliveries")
    assert html =~ "sender@example.net"
  end

  test "delivery details are loaded through context projection", %{conn: conn} do
    owner = owner_fixture()
    %{domain: domain} = mailbox_fixture()
    {:ok, delivery} = delivery_fixture(domain)
    conn = log_in_owner(conn, owner)

    assert {:ok, _view, html} = live(conn, ~p"/deliveries/#{delivery.id}")
    assert html =~ "sender@example.net"
    assert html =~ "inbox@#{domain.normalized_domain}"
    assert html =~ delivery.raw_sha256
  end

  test "raw paths and object-store keys are not exposed as direct public URLs", %{conn: conn} do
    owner = owner_fixture()
    %{domain: domain} = mailbox_fixture()
    {:ok, delivery} = delivery_fixture(domain)

    assert {:error, _} =
             Ingest.archive_delivery(delivery.id, fail_at: :after_archived_state_before_cleanup)

    archived = Repo.get!(Manifold.Ingest.Schema.InboundDelivery, delivery.id)

    conn = log_in_owner(conn, owner)
    assert {:ok, _view, html} = live(conn, ~p"/deliveries/#{delivery.id}")

    refute html =~ archived.spool_bundle_path
    refute html =~ archived.raw_object_key
  end

  defp owner_fixture do
    email = "owner#{System.unique_integer([:positive])}@example.test"
    {:ok, owner} = Accounts.create_owner(%{email: email, password: "long-enough-password"})
    owner
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "web#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_mailbox(domain, %{local_part: "inbox"})
    %{domain: domain, mailbox: mailbox}
  end

  defp delivery_fixture(domain) do
    {:ok, route} = Accounts.resolve_recipient("inbox@#{domain.normalized_domain}")

    Ingest.accept_transport(
      "Subject: web\r\n\r\nBody\r\n",
      %{
        peer_ip: "127.0.0.1",
        helo: "client.example",
        envelope_from: "sender@example.net",
        original_recipients: [route.original_recipient],
        received_at: DateTime.utc_now()
      },
      [route]
    )
  end
end
