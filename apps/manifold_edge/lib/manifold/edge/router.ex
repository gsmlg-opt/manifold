defmodule Manifold.Edge.Router do
  @moduledoc """
  Authenticated machine API used by local Manifold pull workers.
  """

  use Plug.Router

  alias Manifold.Core.{RouteSnapshotDigest, SignedRequest}
  alias Manifold.Edge
  alias Manifold.Edge.RouteSnapshot
  alias Manifold.Edge.RouteSnapshot.Route
  alias Manifold.Storage.Spool
  alias Manifold.Storage.Spool.Manifest

  plug(:match)
  plug(:read_request_body)
  plug(:authenticate)
  plug(:dispatch)

  put "/api/v1/route-snapshots" do
    with {:ok, payload} <- Jason.decode(conn.assigns.raw_body),
         {:ok, snapshot} <- decode_snapshot(payload),
         {:ok, _installed} <- Edge.install_route_snapshot(snapshot) do
      send_resp(conn, 204, "")
    else
      {:error, reason} when is_atom(reason) ->
        error_response(conn, snapshot_error_status(reason), reason)

      {:error, _decode_error} ->
        error_response(conn, 422, :invalid_snapshot)
    end
  end

  get "/api/v1/deliveries" do
    deliveries =
      Edge.list_pending_deliveries()
      |> Enum.map(&delivery_metadata/1)

    json_response(conn, 200, %{deliveries: deliveries})
  end

  get "/api/v1/deliveries/:delivery_id/raw" do
    with {:ok, delivery} <- Edge.get_delivery(delivery_id),
         :ok <- verify_raw(delivery) do
      conn
      |> put_resp_header("cache-control", "no-store, private")
      |> put_resp_content_type("message/rfc822")
      |> send_file(200, Path.join(delivery.spool_bundle_path, "raw.eml"))
    else
      {:error, :not_found} -> error_response(conn, 404, :not_found)
      {:error, _reason} -> error_response(conn, 409, :raw_unavailable)
    end
  end

  post "/api/v1/deliveries/:delivery_id/failures" do
    with {:ok, failure} <- Jason.decode(conn.assigns.raw_body),
         {:ok, _delivery} <- Edge.fail_delivery(delivery_id, failure) do
      send_resp(conn, 204, "")
    else
      {:error, :not_found} -> error_response(conn, 404, :not_found)
      {:error, reason} when is_atom(reason) -> error_response(conn, 409, reason)
      {:error, _decode_error} -> error_response(conn, 422, :invalid_failure)
    end
  end

  post "/api/v1/deliveries/:delivery_id/acknowledgements" do
    with {:ok, acknowledgement} <- Jason.decode(conn.assigns.raw_body),
         {:ok, delivery} <- Edge.acknowledge_delivery(delivery_id, acknowledgement) do
      _cleanup_result = Spool.cleanup_ready_bundle(delivery.spool_bundle_path)
      send_resp(conn, 204, "")
    else
      {:error, :not_found} -> error_response(conn, 404, :not_found)
      {:error, reason} when is_atom(reason) -> error_response(conn, 409, reason)
      {:error, _decode_error} -> error_response(conn, 422, :invalid_acknowledgement)
    end
  end

  get "/api/v1/status" do
    snapshot =
      case Edge.active_route_snapshot() do
        {:ok, active} ->
          %{revision: active.revision, expires_at: active.expires_at, state: "active"}

        {:error, reason} ->
          %{state: Atom.to_string(reason)}
      end

    json_response(conn, 200, %{
      route_snapshot: snapshot,
      pending_deliveries: length(Edge.list_pending_deliveries())
    })
  end

  match _ do
    error_response(conn, 404, :not_found)
  end

  defp read_request_body(conn, _opts) do
    max_bytes = api_config(:max_request_bytes)

    case Plug.Conn.read_body(conn, length: max_bytes, read_length: min(max_bytes, 1_000_000)) do
      {:ok, body, conn} ->
        assign(conn, :raw_body, body)

      {:more, _partial, conn} ->
        conn
        |> error_response(413, :request_too_large)
        |> halt()

      {:error, _reason} ->
        conn
        |> error_response(400, :invalid_request)
        |> halt()
    end
  end

  defp authenticate(conn, _opts) do
    now = DateTime.utc_now()
    max_skew_seconds = api_config(:max_clock_skew_seconds)

    with {:ok, installation_id} <- request_header(conn, "x-manifold-installation"),
         true <- installation_id == api_config(:installation_id),
         {:ok, timestamp_value} <- request_header(conn, "x-manifold-timestamp"),
         {timestamp, ""} <- Integer.parse(timestamp_value),
         {:ok, nonce} <- request_header(conn, "x-manifold-nonce"),
         {:ok, signature} <- request_header(conn, "x-manifold-signature"),
         true <- request_authority_matches?(conn),
         :ok <-
           SignedRequest.verify(
             api_config(:shared_secret),
             signature,
             conn.method,
             conn.request_path,
             timestamp,
             conn.assigns.raw_body,
             now: DateTime.to_unix(now),
             max_skew_seconds: max_skew_seconds,
             request_context: [
               installation_id: installation_id,
               authority: api_config(:authority),
               nonce: nonce
             ]
           ),
         :ok <-
           Edge.claim_nonce(
             installation_id,
             nonce,
             DateTime.from_unix!(timestamp + max_skew_seconds + 1),
             now: now
           ) do
      conn
    else
      _invalid ->
        conn
        |> error_response(401, :invalid_signature)
        |> halt()
    end
  end

  defp request_header(conn, name) do
    case get_req_header(conn, name) do
      [value] when value != "" -> {:ok, value}
      _missing_or_repeated -> {:error, :invalid_header}
    end
  end

  defp decode_snapshot(%{
         "schema_version" => schema_version,
         "revision" => revision,
         "digest" => digest,
         "generated_at" => generated_at,
         "expires_at" => expires_at,
         "domains" => domains,
         "routes" => routes
       })
       when is_list(domains) and is_list(routes) do
    with {:ok, generated_at, _offset} <- DateTime.from_iso8601(generated_at),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires_at),
         :ok <- RouteSnapshotDigest.verify(schema_version, domains, routes, digest),
         {:ok, decoded_routes} <- decode_routes(routes) do
      {:ok,
       %RouteSnapshot{
         schema_version: schema_version,
         revision: revision,
         digest: digest,
         generated_at: generated_at,
         expires_at: expires_at,
         routes: decoded_routes
       }}
    end
  end

  defp decode_snapshot(_payload), do: {:error, :invalid_snapshot}

  defp decode_routes(routes) do
    Enum.reduce_while(routes, {:ok, []}, fn
      %{
        "canonical_address" => address,
        "domain_id" => domain_id,
        "mailbox_ids" => mailbox_ids,
        "plus_addressing_enabled" => plus_enabled
      },
      {:ok, decoded} ->
        route = %Route{
          canonical_address: address,
          domain_id: domain_id,
          mailbox_ids: mailbox_ids,
          plus_addressing_enabled: plus_enabled
        }

        {:cont, {:ok, [route | decoded]}}

      _invalid, _acc ->
        {:halt, {:error, :invalid_snapshot}}
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delivery_metadata(delivery) do
    %{
      edge_delivery_id: delivery.id,
      peer_ip: delivery.peer_ip,
      helo: delivery.helo,
      envelope_from: delivery.envelope_from,
      received_at: delivery.received_at,
      original_recipients: Enum.map(delivery.recipients, & &1.original_address),
      routes:
        Enum.map(delivery.recipients, fn recipient ->
          %{
            original_recipient: recipient.original_address,
            canonical_recipient: recipient.canonical_address,
            plus_tag: recipient.plus_tag,
            domain_id: recipient.domain_id,
            mailbox_ids: recipient.mailbox_ids
          }
        end),
      raw_size: delivery.raw_size,
      raw_sha256: delivery.raw_sha256,
      snapshot_revision: delivery.snapshot_revision
    }
  end

  defp verify_raw(delivery) do
    path = Path.join(delivery.spool_bundle_path, "raw.eml")

    with {:ok, stat} <- File.stat(path),
         true <- stat.size == delivery.raw_size,
         {:ok, digest} <- Manifest.sha256_file(path),
         true <- digest == delivery.raw_sha256 do
      :ok
    else
      _invalid -> {:error, :raw_mismatch}
    end
  end

  defp snapshot_error_status(reason)
       when reason in [:snapshot_conflict, :snapshot_rollback],
       do: 409

  defp snapshot_error_status(_reason), do: 422

  defp json_response(conn, status, payload) do
    conn
    |> put_resp_header("cache-control", "no-store, private")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp error_response(conn, status, reason) do
    json_response(conn, status, %{error: Atom.to_string(reason)})
  end

  defp api_config(key) do
    :manifold_edge
    |> Application.fetch_env!(:api)
    |> Keyword.fetch!(key)
  end

  defp request_authority_matches?(conn) do
    authority = api_config(:authority)
    expected = URI.parse("https://" <> authority)

    host_matches? =
      is_binary(expected.host) and
        String.downcase(conn.host, :ascii) == String.downcase(expected.host, :ascii)

    if Regex.match?(~r/:\d+\z/, authority) do
      host_matches? and conn.port == expected.port
    else
      host_matches?
    end
  end
end
