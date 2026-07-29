defmodule Manifold.Edge.RouterTest do
  use Manifold.Edge.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Manifold.Core.{RouteSnapshotDigest, SignedRequest}
  alias Manifold.Edge
  alias Manifold.Edge.Reconciler
  alias Manifold.Edge.Router
  alias Manifold.Edge.RouteSnapshot
  alias Manifold.Edge.RouteSnapshot.Route
  alias Manifold.Edge.Schema.Nonce
  alias Manifold.Edge.SMTP

  @moduletag :tmp_dir
  @secret "shared-edge-secret"
  @installation_id "installation-1"
  @authority "edge.example.test"

  setup do
    previous = Application.get_env(:manifold_edge, :api)

    Application.put_env(:manifold_edge, :api,
      installation_id: @installation_id,
      authority: @authority,
      shared_secret: @secret,
      max_clock_skew_seconds: 300,
      max_request_bytes: 1_000_000
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:manifold_edge, :api, previous)
      else
        Application.delete_env(:manifold_edge, :api)
      end
    end)
  end

  test "installs snapshots and rejects a replayed signed request" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    body = snapshot_body(now)

    conn =
      :put
      |> signed_conn("/api/v1/route-snapshots", body, "snapshot-nonce", now)
      |> Router.call([])

    assert conn.status == 204
    assert {:ok, %{revision: 1}} = Edge.active_route_snapshot(now: now)

    replay =
      :put
      |> signed_conn("/api/v1/route-snapshots", body, "snapshot-nonce", now)
      |> Router.call([])

    assert replay.status == 401
  end

  test "rejects a valid signature sent to a different authority" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    body = snapshot_body(now)

    conn =
      :put
      |> signed_conn("/api/v1/route-snapshots", body, "wrong-host-nonce", now)
      |> Map.put(:host, "other.example.test")
      |> Router.call([])

    assert conn.status == 401
  end

  test "retains a future-timestamp nonce for the full signature validity window", %{
    tmp_dir: tmp_dir
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    request_time = DateTime.add(now, 299, :second)
    body = snapshot_body(now)

    request =
      signed_conn(
        :put,
        "/api/v1/route-snapshots",
        body,
        "future-clock-nonce",
        request_time
      )

    assert Router.call(request, []).status == 204
    nonce = Repo.one!(Nonce)

    assert DateTime.to_unix(nonce.expires_at) ==
             request_time |> DateTime.add(301, :second) |> DateTime.to_unix()

    assert :ok =
             Reconciler.run(
               root: tmp_dir,
               orphan_retention_seconds: 3600,
               now: DateTime.add(now, 301, :second)
             )

    assert Repo.aggregate(Nonce, :count) == 1
    assert Router.call(request, []).status == 401
  end

  test "rejects a signed snapshot whose canonical digest does not match" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    body =
      now
      |> snapshot_body()
      |> Jason.decode!()
      |> put_in(["routes", Access.at(0), "mailbox_ids"], ["mailbox-2"])
      |> Jason.encode!()

    conn =
      :put
      |> signed_conn("/api/v1/route-snapshots", body, "bad-digest-nonce", now)
      |> Router.call([])

    assert conn.status == 422
  end

  test "lists and serves raw deliveries without exposing paths, then cleans up after ack", %{
    tmp_dir: tmp_dir
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    install_snapshot(now)
    {:ok, snapshot} = SMTP.begin_transaction(now: now)
    {:ok, route} = SMTP.resolve_recipient("team@example.test", snapshot)

    {:ok, delivery} =
      SMTP.accept_transport(
        "raw\n",
        %{
          peer_ip: "192.0.2.10",
          helo: "sender.example",
          envelope_from: "sender@example.net",
          received_at: now,
          original_recipients: ["team@example.test"]
        },
        [route],
        spool_opts: [root: tmp_dir]
      )

    listed =
      :get
      |> signed_conn("/api/v1/deliveries", "", "list-nonce", now)
      |> Router.call([])

    assert listed.status == 200
    assert get_resp_header(listed, "cache-control") == ["no-store, private"]
    assert %{"deliveries" => [metadata]} = Jason.decode!(listed.resp_body)
    assert metadata["edge_delivery_id"] == delivery.id
    assert metadata["routes"] |> hd() |> Map.fetch!("mailbox_ids") == ["mailbox-1"]
    refute Map.has_key?(metadata, "spool_bundle_path")

    raw =
      :get
      |> signed_conn("/api/v1/deliveries/#{delivery.id}/raw", "", "raw-nonce", now)
      |> Router.call([])

    assert raw.status == 200
    assert get_resp_header(raw, "cache-control") == ["no-store, private"]
    assert raw.resp_body == "raw\n"

    acknowledgement =
      Jason.encode!(%{
        local_delivery_id: Ecto.UUID.generate(),
        raw_sha256: delivery.raw_sha256
      })

    acknowledged =
      :post
      |> signed_conn(
        "/api/v1/deliveries/#{delivery.id}/acknowledgements",
        acknowledgement,
        "ack-nonce",
        now
      )
      |> Router.call([])

    assert acknowledged.status == 204
    refute File.exists?(delivery.spool_bundle_path)
    assert [] == Edge.list_pending_deliveries()
  end

  test "isolates a permanently rejected delivery without removing its raw bundle", %{
    tmp_dir: tmp_dir
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    install_snapshot(now)
    {:ok, snapshot} = SMTP.begin_transaction(now: now)
    {:ok, route} = SMTP.resolve_recipient("team@example.test", snapshot)

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

    failure =
      Jason.encode!(%{
        raw_sha256: delivery.raw_sha256,
        reason: "edge_raw_mismatch"
      })

    failed =
      :post
      |> signed_conn(
        "/api/v1/deliveries/#{delivery.id}/failures",
        failure,
        "failure-nonce",
        now
      )
      |> Router.call([])

    assert failed.status == 204
    assert {:ok, %{state: "failed"}} = Edge.get_delivery(delivery.id)
    assert File.dir?(delivery.spool_bundle_path)
  end

  defp signed_conn(method, path, body, nonce, now) do
    timestamp = DateTime.to_unix(now)

    context = [
      installation_id: @installation_id,
      authority: @authority,
      nonce: nonce
    ]

    signature = SignedRequest.sign(@secret, to_string(method), path, timestamp, body, context)

    method
    |> conn(path, body)
    |> Map.put(:host, @authority)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-manifold-installation", @installation_id)
    |> put_req_header("x-manifold-timestamp", Integer.to_string(timestamp))
    |> put_req_header("x-manifold-nonce", nonce)
    |> put_req_header("x-manifold-signature", signature)
  end

  defp snapshot_body(now) do
    domains = []

    routes = [
      %{
        canonical_address: "team@example.test",
        domain_id: "domain-1",
        mailbox_ids: ["mailbox-1"],
        plus_addressing_enabled: true
      }
    ]

    {:ok, digest} = RouteSnapshotDigest.compute(1, domains, routes)

    Jason.encode!(%{
      schema_version: 1,
      revision: 1,
      digest: digest,
      generated_at: DateTime.add(now, -60, :second),
      expires_at: DateTime.add(now, 3600, :second),
      domains: domains,
      routes: routes
    })
  end

  defp install_snapshot(now) do
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

    assert {:ok, _installed} = Edge.install_route_snapshot(snapshot, now: now)
  end
end
