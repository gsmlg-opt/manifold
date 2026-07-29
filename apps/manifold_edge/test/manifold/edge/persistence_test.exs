defmodule Manifold.Edge.PersistenceTest do
  use Manifold.Edge.DataCase, async: false

  alias Manifold.Edge
  alias Manifold.Edge.RouteSnapshot
  alias Manifold.Edge.RouteSnapshot.Route

  alias Manifold.Edge.Schema.{
    Delivery,
    DeliveryEvent,
    InstalledRoute,
    InstalledRouteSnapshot,
    Nonce
  }

  @now ~U[2026-07-29 12:00:00.000000Z]

  test "installs and reads an active route snapshot atomically" do
    snapshot = snapshot(7, "a")

    assert {:ok, installed} = Edge.install_route_snapshot(snapshot, now: @now)
    assert installed.revision == 7
    assert installed.active
    assert Repo.aggregate(InstalledRouteSnapshot, :count) == 1
    assert Repo.aggregate(InstalledRoute, :count) == 2

    assert {:ok, active} = Edge.active_route_snapshot(now: @now)
    assert active == snapshot
  end

  test "reinstalling the same revision and digest is idempotent" do
    snapshot = snapshot(7, "a")

    assert {:ok, first} = Edge.install_route_snapshot(snapshot, now: @now)
    assert {:ok, second} = Edge.install_route_snapshot(snapshot, now: @now)

    assert second.id == first.id
    assert Repo.aggregate(InstalledRouteSnapshot, :count) == 1
    assert Repo.aggregate(InstalledRoute, :count) == 2
  end

  test "same revision and digest refreshes the signed validity envelope" do
    snapshot = snapshot(7, "a")
    assert {:ok, first} = Edge.install_route_snapshot(snapshot, now: @now)

    refreshed = %{
      snapshot
      | generated_at: DateTime.add(snapshot.generated_at, 60, :second),
        expires_at: DateTime.add(snapshot.expires_at, 3600, :second)
    }

    assert {:ok, second} = Edge.install_route_snapshot(refreshed, now: @now)
    assert second.id == first.id
    assert second.generated_at == refreshed.generated_at
    assert second.expires_at == refreshed.expires_at
    assert Repo.aggregate(InstalledRouteSnapshot, :count) == 1
  end

  test "rejects revision conflicts, rollbacks, and expired snapshots" do
    assert {:ok, _installed} =
             Edge.install_route_snapshot(snapshot(7, "a"), now: @now)

    assert {:error, :snapshot_conflict} =
             Edge.install_route_snapshot(snapshot(7, "b"), now: @now)

    assert {:error, :snapshot_rollback} =
             Edge.install_route_snapshot(snapshot(6, "c"), now: @now)

    expired = %{snapshot(8, "d") | expires_at: DateTime.add(@now, -1, :second)}

    assert {:error, :snapshot_expired} =
             Edge.install_route_snapshot(expired, now: @now)
  end

  test "activating a newer revision deactivates the previous snapshot" do
    assert {:ok, old} = Edge.install_route_snapshot(snapshot(7, "a"), now: @now)
    assert {:ok, current} = Edge.install_route_snapshot(snapshot(8, "b"), now: @now)

    refute Repo.get!(InstalledRouteSnapshot, old.id).active
    assert Repo.get!(InstalledRouteSnapshot, current.id).active
    assert {:ok, %{revision: 8}} = Edge.active_route_snapshot(now: @now)
  end

  test "lists ready deliveries with frozen recipients in acceptance order" do
    install_snapshot()
    first = record_delivery("ingest-1", DateTime.add(@now, -10, :second))
    second = record_delivery("ingest-2", @now)

    assert [listed_first, listed_second] = Edge.list_pending_deliveries()
    assert [listed_first.id, listed_second.id] == [first.id, second.id]
    assert [%{original_address: "team+ops@example.test"}] = listed_first.recipients
    assert Enum.map(listed_first.events, & &1.event_type) == ["accepted"]
  end

  test "rejects a repeated ingest id with conflicting frozen recipients" do
    install_snapshot()
    record_delivery("ingest-1", @now)

    conflicting_recipients = [
      %{
        original_address: "billing@example.test",
        canonical_address: "billing@example.test",
        plus_tag: nil,
        domain_id: "domain-1",
        mailbox_ids: ["mailbox-3"]
      }
    ]

    assert {:error, :delivery_conflict} =
             Edge.record_delivery(
               delivery_attrs("ingest-1", @now),
               conflicting_recipients,
               now: @now
             )

    assert Repo.aggregate(Delivery, :count) == 1
  end

  test "acknowledges a delivery idempotently and excludes it from pending work" do
    install_snapshot()
    delivery = record_delivery("ingest-1", @now)
    local_delivery_id = Ecto.UUID.generate()

    acknowledgement = %{
      local_delivery_id: local_delivery_id,
      raw_sha256: delivery.raw_sha256
    }

    assert {:ok, acknowledged} =
             Edge.acknowledge_delivery(delivery.id, acknowledgement, now: @now)

    assert acknowledged.state == "acknowledged"
    assert acknowledged.local_delivery_id == local_delivery_id
    assert acknowledged.acknowledged_at == @now

    assert {:ok, repeated} =
             Edge.acknowledge_delivery(delivery.id, acknowledgement, now: @now)

    assert repeated.id == acknowledged.id
    assert Edge.list_pending_deliveries() == []

    assert Repo.aggregate(
             from(event in DeliveryEvent,
               where: event.delivery_id == ^delivery.id and event.event_type == "acknowledged"
             ),
             :count
           ) == 1
  end

  test "rejects conflicting acknowledgement identity or digest" do
    install_snapshot()
    delivery = record_delivery("ingest-1", @now)

    assert {:error, :digest_mismatch} =
             Edge.acknowledge_delivery(
               delivery.id,
               %{local_delivery_id: Ecto.UUID.generate(), raw_sha256: String.duplicate("f", 64)},
               now: @now
             )

    local_delivery_id = Ecto.UUID.generate()

    assert {:ok, _acknowledged} =
             Edge.acknowledge_delivery(
               delivery.id,
               %{local_delivery_id: local_delivery_id, raw_sha256: delivery.raw_sha256},
               now: @now
             )

    assert {:error, :acknowledgement_conflict} =
             Edge.acknowledge_delivery(
               delivery.id,
               %{
                 local_delivery_id: Ecto.UUID.generate(),
                 raw_sha256: delivery.raw_sha256
               },
               now: @now
             )
  end

  test "isolates a permanent local import failure idempotently without acknowledgement" do
    install_snapshot()
    delivery = record_delivery("ingest-1", @now)

    failure = %{
      raw_sha256: delivery.raw_sha256,
      reason: "edge_raw_mismatch"
    }

    assert {:ok, failed} = Edge.fail_delivery(delivery.id, failure, now: @now)
    assert failed.state == "failed"
    assert failed.last_error == "local import failed: edge_raw_mismatch"
    assert failed.local_delivery_id == nil
    assert Edge.list_pending_deliveries() == []

    assert {:ok, repeated} = Edge.fail_delivery(delivery.id, failure, now: @now)
    assert repeated.id == failed.id

    assert {:ok, repeated} =
             Edge.fail_delivery(
               delivery.id,
               %{failure | reason: "ingress_conflict"},
               now: @now
             )

    assert repeated.last_error == failed.last_error

    assert Repo.aggregate(
             from(event in DeliveryEvent,
               where: event.delivery_id == ^delivery.id and event.event_type == "import_failed"
             ),
             :count
           ) == 1
  end

  test "claims a nonce once and rejects expired or replayed nonces" do
    expires_at = DateTime.add(@now, 300, :second)

    assert :ok = Edge.claim_nonce("key-1", "nonce-1", expires_at, now: @now)
    assert {:error, :replayed_nonce} = Edge.claim_nonce("key-1", "nonce-1", expires_at, now: @now)

    assert :ok = Edge.claim_nonce("key-2", "nonce-1", expires_at, now: @now)

    assert {:error, :expired_nonce} =
             Edge.claim_nonce("key-1", "nonce-2", @now, now: @now)

    assert Repo.aggregate(Nonce, :count) == 2
  end

  defp install_snapshot do
    assert {:ok, _installed} = Edge.install_route_snapshot(snapshot(7, "a"), now: @now)
  end

  defp record_delivery(ingest_id, received_at) do
    assert {:ok, %Delivery{} = delivery} =
             Edge.record_delivery(
               delivery_attrs(ingest_id, received_at),
               delivery_recipients(),
               now: received_at
             )

    delivery
  end

  defp delivery_attrs(ingest_id, received_at) do
    %{
      ingest_id: ingest_id,
      snapshot_revision: 7,
      peer_ip: "192.0.2.10",
      helo: "sender.example",
      envelope_from: "sender@example.test",
      received_at: received_at,
      raw_size: 42,
      raw_sha256: String.duplicate("e", 64),
      spool_bundle_path: "/trusted/spool/ready/#{ingest_id}"
    }
  end

  defp delivery_recipients do
    [
      %{
        original_address: "team+ops@example.test",
        canonical_address: "team@example.test",
        plus_tag: "ops",
        domain_id: "domain-1",
        mailbox_ids: ["mailbox-1", "mailbox-2"]
      }
    ]
  end

  defp snapshot(revision, digest_character) do
    %RouteSnapshot{
      schema_version: 1,
      revision: revision,
      digest: String.duplicate(digest_character, 64),
      generated_at: DateTime.add(@now, -60, :second),
      expires_at: DateTime.add(@now, 3600, :second),
      routes: [
        %Route{
          canonical_address: "team@example.test",
          domain_id: "domain-1",
          mailbox_ids: ["mailbox-1", "mailbox-2"],
          plus_addressing_enabled: true
        },
        %Route{
          canonical_address: "billing@example.test",
          domain_id: "domain-1",
          mailbox_ids: ["mailbox-3"],
          plus_addressing_enabled: false
        }
      ]
    }
  end
end
