defmodule Manifold.Cloud.Synchronizer do
  @moduledoc """
  Imports one edge delivery through the local durable ingest boundary.
  """

  alias Manifold.Cloud.Client
  alias Manifold.Core.Error
  alias Manifold.Ingest
  alias Manifold.Storage.Spool
  alias Manifold.Storage.Spool.Manifest

  @spec sync_delivery(keyword(), map(), keyword()) :: :ok | {:error, Error.t()}
  def sync_delivery(source, metadata, opts \\ []) when is_map(metadata) do
    client = Keyword.get(opts, :client, Client)
    ingest = Keyword.get(opts, :ingest, Ingest)
    client_opts = Keyword.get(opts, :client_opts, [])

    with {:ok, delivery} <- validate_metadata(metadata),
         {:ok, receipt} <-
           ensure_local_acceptance(source, delivery, client, ingest, client_opts, opts),
         :ok <-
           client.acknowledge(
             source,
             delivery.edge_delivery_id,
             receipt.inbound_delivery_id,
             receipt.raw_sha256,
             client_opts
           ) do
      :ok
    end
  end

  defp ensure_local_acceptance(source, delivery, client, ingest, client_opts, opts) do
    source_id = Keyword.fetch!(source, :source_id)

    case ingest.lookup_ingress(source_id, delivery.edge_delivery_id) do
      {:ok, receipt} ->
        {:ok, receipt}

      {:error, %Error{reason: :not_found}} ->
        import_delivery(source, delivery, client, ingest, client_opts, opts)

      {:error, %Error{}} = failure ->
        failure
    end
  end

  defp import_delivery(source, delivery, client, ingest, client_opts, opts) do
    source_id = Keyword.fetch!(source, :source_id)

    with {:ok, bundle} <-
           load_or_fetch_bundle(source, source_id, delivery, client, client_opts, opts),
         :ok <- verify_bundle(bundle, delivery),
         {:ok, receipt} <-
           ingest.accept_edge(source_id, delivery.edge_delivery_id, bundle, delivery.routes) do
      {:ok, receipt}
    end
  end

  defp load_or_fetch_bundle(source, source_id, delivery, client, client_opts, opts) do
    ingest_id = local_ingest_id(source_id, delivery.edge_delivery_id)
    spool_opts = Keyword.get(opts, :spool_opts, [])
    root = Keyword.get_lazy(spool_opts, :root, &Spool.spool_root/0)
    bundle = Spool.bundle_for(root, ingest_id)

    if File.dir?(bundle.path) do
      load_existing_bundle(bundle)
    else
      with {:ok, raw_stream} <-
             client.stream_raw(source, delivery.edge_delivery_id, client_opts) do
        write_local_bundle(source_id, delivery, raw_stream, opts)
      end
    end
  end

  defp load_existing_bundle(bundle) do
    case Spool.read_manifest(bundle.path) do
      {:ok, manifest} ->
        {:ok, %{bundle | manifest: manifest}}

      {:error, reason} ->
        _move_result =
          Spool.move_ready_to_failed(
            bundle.root,
            bundle.ingest_id,
            "invalid-cloud-import"
          )

        {:error,
         Error.new(:temporary, :invalid_local_spool_bundle, "local spool manifest is invalid", %{
           reason: inspect(reason)
         })}
    end
  end

  defp write_local_bundle(source_id, delivery, raw_stream, opts) do
    spool_opts =
      opts
      |> Keyword.get(:spool_opts, [])
      |> Keyword.put(:max_bytes, delivery.raw_size)
      |> Keyword.put(:ingest_id, local_ingest_id(source_id, delivery.edge_delivery_id))

    attrs = %{
      ingest_id: spool_opts[:ingest_id],
      peer_ip: delivery.peer_ip,
      helo: delivery.helo,
      envelope_from: delivery.envelope_from,
      received_at: delivery.received_at,
      original_recipients: delivery.original_recipients,
      routes: delivery.routes
    }

    Spool.write_bundle_from_stream(raw_stream, attrs, spool_opts)
  end

  defp verify_bundle(bundle, delivery) do
    manifest = bundle.manifest

    with true <- manifest.ingest_id == bundle.ingest_id,
         true <- manifest.raw_size == delivery.raw_size,
         true <- manifest.raw_sha256 == delivery.raw_sha256,
         {:ok, stat} <- File.stat(bundle.raw_path),
         true <- stat.size == delivery.raw_size,
         {:ok, raw_sha256} <- Manifest.sha256_file(bundle.raw_path),
         true <- raw_sha256 == delivery.raw_sha256 do
      :ok
    else
      _invalid ->
        _move_result =
          Spool.move_ready_to_failed(bundle.root, bundle.ingest_id, "cloud-raw-mismatch")

        {:error,
         Error.new(
           :permanent,
           :edge_raw_mismatch,
           "edge raw content does not match its declared size and SHA-256"
         )}
    end
  end

  defp validate_metadata(metadata) do
    with edge_delivery_id when is_binary(edge_delivery_id) <-
           Map.get(metadata, "edge_delivery_id"),
         peer_ip when is_binary(peer_ip) <- Map.get(metadata, "peer_ip"),
         raw_size when is_integer(raw_size) and raw_size >= 0 <- Map.get(metadata, "raw_size"),
         raw_sha256 when is_binary(raw_sha256) and byte_size(raw_sha256) == 64 <-
           Map.get(metadata, "raw_sha256"),
         routes when is_list(routes) and routes != [] <- Map.get(metadata, "routes"),
         original_recipients when is_list(original_recipients) <-
           Map.get(metadata, "original_recipients"),
         {:ok, received_at, 0} <- DateTime.from_iso8601(Map.get(metadata, "received_at", "")) do
      {:ok,
       %{
         edge_delivery_id: edge_delivery_id,
         peer_ip: peer_ip,
         helo: Map.get(metadata, "helo"),
         envelope_from: Map.get(metadata, "envelope_from"),
         received_at: received_at,
         original_recipients: original_recipients,
         routes: routes,
         raw_size: raw_size,
         raw_sha256: String.downcase(raw_sha256, :ascii)
       }}
    else
      _invalid ->
        {:error,
         Error.new(:permanent, :invalid_edge_delivery, "edge delivery metadata is invalid")}
    end
  end

  defp local_ingest_id(source_id, edge_delivery_id) do
    digest =
      :crypto.hash(:sha256, source_id <> "\x00" <> edge_delivery_id)
      |> Base.encode16(case: :lower)

    "edge-" <> digest
  end
end
