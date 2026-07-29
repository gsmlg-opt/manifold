defmodule Manifold.Edge.ReconcilerTest do
  use Manifold.Edge.DataCase, async: false

  alias Manifold.Edge
  alias Manifold.Edge.Reconciler
  alias Manifold.Edge.RouteSnapshot
  alias Manifold.Edge.RouteSnapshot.Route
  alias Manifold.Edge.Schema.{Delivery, DeliveryEvent, Nonce}
  alias Manifold.Edge.SMTP
  alias Manifold.Storage.Spool

  @moduletag :tmp_dir

  test "removes a verified bundle left after acknowledgement commits", %{tmp_dir: tmp_dir} do
    delivery = accepted_delivery(tmp_dir)

    assert {:ok, _acknowledged} =
             Edge.acknowledge_delivery(delivery.id, %{
               local_delivery_id: Ecto.UUID.generate(),
               raw_sha256: delivery.raw_sha256
             })

    assert File.dir?(delivery.spool_bundle_path)
    assert :ok = Reconciler.run(root: tmp_dir, orphan_retention_seconds: 3600)
    refute File.exists?(delivery.spool_bundle_path)
  end

  test "marks a ready delivery failed when its spool bundle is missing", %{tmp_dir: tmp_dir} do
    delivery = accepted_delivery(tmp_dir)
    :ok = Spool.remove_ready_bundle(delivery.spool_bundle_path)

    assert :ok = Reconciler.run(root: tmp_dir, orphan_retention_seconds: 3600)
    assert %{state: "failed", last_error: last_error} = Repo.get!(Delivery, delivery.id)
    assert last_error =~ "missing"

    assert {:ok, _restored_bundle} =
             Spool.write_bundle(
               "raw\n",
               %{
                 peer_ip: delivery.peer_ip,
                 received_at: delivery.received_at,
                 original_recipients: [],
                 routes: []
               },
               root: tmp_dir,
               ingest_id: delivery.ingest_id
             )

    assert :ok = Reconciler.run(root: tmp_dir, orphan_retention_seconds: 3600)
    assert %{state: "ready", last_error: nil} = Repo.get!(Delivery, delivery.id)

    assert Repo.aggregate(
             from(event in DeliveryEvent,
               where: event.delivery_id == ^delivery.id and event.event_type == "spool_restored"
             ),
             :count
           ) == 1
  end

  test "keeps a delivery ready when checking the spool returns a transient error", %{
    tmp_dir: tmp_dir
  } do
    delivery = accepted_delivery(tmp_dir)

    assert :ok =
             Reconciler.run(
               root: tmp_dir,
               orphan_retention_seconds: 3600,
               stat_fun: fn _path -> {:error, :eio} end
             )

    assert %{state: "ready", last_error: last_error} = Repo.get!(Delivery, delivery.id)
    assert last_error =~ "eio"

    assert :ok = Reconciler.run(root: tmp_dir, orphan_retention_seconds: 3600)
    assert %{state: "ready", last_error: nil} = Repo.get!(Delivery, delivery.id)
  end

  test "resumes cleanup from an acknowledged bundle tombstone", %{tmp_dir: tmp_dir} do
    delivery = accepted_delivery(tmp_dir)

    assert {:ok, _acknowledged} =
             Edge.acknowledge_delivery(delivery.id, %{
               local_delivery_id: Ecto.UUID.generate(),
               raw_sha256: delivery.raw_sha256
             })

    assert {:error, %{reason: :after_cleanup_rename}} =
             Spool.cleanup_ready_bundle(
               delivery.spool_bundle_path,
               fail_at: :after_cleanup_rename
             )

    refute File.exists?(delivery.spool_bundle_path)
    assert [_tombstone] = Path.wildcard(Path.join([tmp_dir, "quarantine", "cleanup-*"]))

    assert :ok = Reconciler.run(root: tmp_dir, orphan_retention_seconds: 3600)
    assert [] == Path.wildcard(Path.join([tmp_dir, "quarantine", "cleanup-*"]))
  end

  test "moves an expired ready bundle without a database row to failed", %{tmp_dir: tmp_dir} do
    {:ok, bundle} =
      Spool.write_bundle(
        "orphan",
        %{
          peer_ip: "192.0.2.10",
          received_at: DateTime.utc_now(),
          original_recipients: [],
          routes: []
        },
        root: tmp_dir,
        ingest_id: "orphan-1"
      )

    assert File.dir?(bundle.path)
    assert :ok = Reconciler.run(root: tmp_dir, orphan_retention_seconds: 0)
    refute File.exists?(bundle.path)
    assert [_failed] = Path.wildcard(Path.join([tmp_dir, "failed", "orphan-*"]))
  end

  test "prunes expired signature nonces", %{tmp_dir: tmp_dir} do
    now = DateTime.utc_now()

    expired =
      Nonce.claim_changeset(%Nonce{}, %{
        key_id: "key-1",
        nonce_digest: String.duplicate("a", 64),
        expires_at: DateTime.add(now, -1, :second),
        claimed_at: DateTime.add(now, -60, :second)
      })

    active =
      Nonce.claim_changeset(%Nonce{}, %{
        key_id: "key-1",
        nonce_digest: String.duplicate("b", 64),
        expires_at: DateTime.add(now, 60, :second),
        claimed_at: now
      })

    Repo.insert!(expired)
    active = Repo.insert!(active)

    assert :ok = Reconciler.run(root: tmp_dir, orphan_retention_seconds: 3600, now: now)
    assert [remaining] = Repo.all(Nonce)
    assert remaining.id == active.id
  end

  defp accepted_delivery(tmp_dir) do
    now = DateTime.utc_now()

    snapshot = %RouteSnapshot{
      schema_version: 1,
      revision: 1,
      digest: String.duplicate("a", 64),
      generated_at: DateTime.add(now, -60, :second),
      expires_at: DateTime.add(now, 3600, :second),
      routes: [
        %Route{
          canonical_address: "team@example.test",
          domain_id: "domain-1",
          mailbox_ids: ["mailbox-1"],
          plus_addressing_enabled: true
        }
      ]
    }

    {:ok, _installed} = Edge.install_route_snapshot(snapshot, now: now)
    {:ok, frozen} = SMTP.begin_transaction(now: now)
    {:ok, route} = SMTP.resolve_recipient("team@example.test", frozen)

    {:ok, delivery} =
      SMTP.accept_transport(
        "raw\n",
        %{
          peer_ip: "192.0.2.10",
          received_at: now,
          original_recipients: ["team@example.test"]
        },
        [route],
        spool_opts: [root: tmp_dir]
      )

    delivery
  end
end
