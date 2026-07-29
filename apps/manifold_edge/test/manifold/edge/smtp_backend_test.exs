defmodule Manifold.Edge.SMTPBackendTest do
  use Manifold.Edge.DataCase, async: false

  alias Manifold.Edge
  alias Manifold.Edge.RouteSnapshot
  alias Manifold.Edge.RouteSnapshot.Route, as: SnapshotRoute
  alias Manifold.Edge.Schema.Delivery
  alias Manifold.Edge.SMTP

  @moduletag :tmp_dir

  test "pins a route snapshot and durably records accepted DATA", %{tmp_dir: tmp_dir} do
    now = DateTime.utc_now()
    install_snapshot(now)

    assert {:ok, snapshot} = SMTP.begin_transaction(now: now)
    assert {:ok, route} = SMTP.resolve_recipient("team+ops@example.test", snapshot)

    attrs = %{
      peer_ip: "192.0.2.10",
      helo: "sender.example",
      envelope_from: "sender@example.net",
      original_recipients: [route.original_recipient],
      received_at: now
    }

    assert {:ok, delivery} =
             SMTP.accept_transport("Subject: edge\r\n\r\nBody\r\n", attrs, [route],
               spool_opts: [root: tmp_dir]
             )

    assert %Delivery{} = Repo.get!(Delivery, delivery.id)
    assert delivery.snapshot_revision == snapshot.revision

    assert File.read!(Path.join(delivery.spool_bundle_path, "raw.eml")) ==
             "Subject: edge\r\n\r\nBody\r\n"

    assert [%{original_address: "team+ops@example.test"}] = delivery.recipients
  end

  test "a crash after ready rename leaves an orphan and no accepted edge row", %{tmp_dir: tmp_dir} do
    now = DateTime.utc_now()
    install_snapshot(now)
    {:ok, snapshot} = SMTP.begin_transaction(now: now)
    {:ok, route} = SMTP.resolve_recipient("team@example.test", snapshot)

    attrs = %{
      peer_ip: "192.0.2.10",
      helo: nil,
      envelope_from: "",
      original_recipients: [route.original_recipient],
      received_at: now
    }

    assert {:error, %{class: :temporary, reason: :after_spool_before_record}} =
             SMTP.accept_transport("raw", attrs, [route],
               spool_opts: [root: tmp_dir],
               fail_at: :after_spool_before_record
             )

    assert Repo.aggregate(Delivery, :count) == 0
    assert [_ready_bundle] = Path.wildcard(Path.join([tmp_dir, "ready", "*"]))
  end

  defp install_snapshot(now) do
    snapshot = %RouteSnapshot{
      schema_version: 1,
      revision: 1,
      digest: String.duplicate("a", 64),
      generated_at: DateTime.add(now, -60, :second),
      expires_at: DateTime.add(now, 3600, :second),
      routes: [
        %SnapshotRoute{
          canonical_address: "team@example.test",
          domain_id: "domain-1",
          mailbox_ids: ["mailbox-1"],
          plus_addressing_enabled: true
        }
      ]
    }

    assert {:ok, _installed} = Edge.install_route_snapshot(snapshot, now: now)
  end
end
