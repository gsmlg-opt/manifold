defmodule Manifold.Cloud.ClientTest do
  use ExUnit.Case, async: true

  alias Manifold.Accounts.RecipientSnapshot
  alias Manifold.Cloud.Client
  alias Manifold.Core.SignedRequest

  @timestamp 1_754_953_200
  @source [
    base_url: "https://edge.example.test",
    authority: "edge.example.test",
    installation_id: "installation-1",
    secret: "shared-edge-secret",
    req_options: [plug: {Req.Test, Client}]
  ]

  test "publishes a recipient snapshot with a signature bound to the request" do
    snapshot = %RecipientSnapshot{
      schema_version: 1,
      revision: 9,
      generated_at: ~U[2026-07-29 12:00:00Z],
      expires_at: ~U[2026-07-30 12:00:00Z],
      digest: String.duplicate("a", 64),
      domains: [],
      routes: []
    }

    Req.Test.expect(Client, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/api/v1/route-snapshots"
      assert [timestamp] = Plug.Conn.get_req_header(conn, "x-manifold-timestamp")
      assert ["installation-1"] = Plug.Conn.get_req_header(conn, "x-manifold-installation")
      assert ["nonce-1"] = Plug.Conn.get_req_header(conn, "x-manifold-nonce")
      assert [signature] = Plug.Conn.get_req_header(conn, "x-manifold-signature")
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert :ok =
               SignedRequest.verify(
                 "shared-edge-secret",
                 signature,
                 "PUT",
                 "/api/v1/route-snapshots",
                 String.to_integer(timestamp),
                 body,
                 now: @timestamp,
                 request_context: [
                   installation_id: "installation-1",
                   authority: "edge.example.test",
                   nonce: "nonce-1"
                 ]
               )

      assert Jason.decode!(body)["revision"] == 9
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok =
             Client.publish_snapshot(@source, snapshot,
               now: @timestamp,
               nonce: "nonce-1"
             )
  end

  test "lists, fetches, and acknowledges edge deliveries through signed requests" do
    Req.Test.expect(Client, 4, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/deliveries"} ->
          assert_signed(conn, "")

          Req.Test.json(conn, %{
            "deliveries" => [
              %{
                "edge_delivery_id" => "edge-1",
                "raw_size" => 4,
                "raw_sha256" => String.duplicate("a", 64)
              }
            ]
          })

        {"GET", "/api/v1/deliveries/edge-1/raw"} ->
          assert_signed(conn, "")
          Plug.Conn.send_resp(conn, 200, "raw\n")

        {"POST", "/api/v1/deliveries/edge-1/acknowledgements"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert_signed(conn, body)

          assert Jason.decode!(body) == %{
                   "local_delivery_id" => "local-1",
                   "raw_sha256" => String.duplicate("a", 64)
                 }

          Plug.Conn.send_resp(conn, 204, "")

        {"POST", "/api/v1/deliveries/edge-1/failures"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert_signed(conn, body)

          assert Jason.decode!(body) == %{
                   "raw_sha256" => String.duplicate("a", 64),
                   "reason" => "edge_raw_mismatch"
                 }

          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    opts = [now: @timestamp, nonce: "nonce-1"]

    assert {:ok, [%{"edge_delivery_id" => "edge-1"} = delivery]} =
             Client.list_deliveries(@source, opts)

    assert delivery["raw_size"] == 4
    assert {:ok, raw_stream} = Client.stream_raw(@source, "edge-1", opts)
    assert Enum.join(raw_stream) == "raw\n"

    assert :ok =
             Client.acknowledge(
               @source,
               "edge-1",
               "local-1",
               String.duplicate("a", 64),
               opts
             )

    assert :ok =
             Client.report_failure(
               @source,
               "edge-1",
               String.duplicate("a", 64),
               :edge_raw_mismatch,
               opts
             )
  end

  defp assert_signed(conn, body) do
    assert [timestamp] = Plug.Conn.get_req_header(conn, "x-manifold-timestamp")
    assert [installation_id] = Plug.Conn.get_req_header(conn, "x-manifold-installation")
    assert [nonce] = Plug.Conn.get_req_header(conn, "x-manifold-nonce")
    assert [signature] = Plug.Conn.get_req_header(conn, "x-manifold-signature")

    assert :ok =
             SignedRequest.verify(
               "shared-edge-secret",
               signature,
               conn.method,
               conn.request_path,
               String.to_integer(timestamp),
               body,
               now: @timestamp,
               request_context: [
                 installation_id: installation_id,
                 authority: "edge.example.test",
                 nonce: nonce
               ]
             )
  end
end
