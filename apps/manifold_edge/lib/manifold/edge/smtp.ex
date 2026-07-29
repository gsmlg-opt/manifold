defmodule Manifold.Edge.SMTP do
  @moduledoc """
  Edge resolver and durable acceptor configured into `manifold_smtp`.
  """

  @behaviour Manifold.SMTP.Acceptor
  @behaviour Manifold.SMTP.Resolver

  alias Manifold.Core.Error
  alias Manifold.Edge
  alias Manifold.Edge.{Route, RouteResolver, RouteSnapshot}
  alias Manifold.Storage.Spool

  @impl Manifold.SMTP.Resolver
  @spec begin_transaction() :: {:ok, RouteSnapshot.t()} | {:error, Error.t()}
  def begin_transaction, do: begin_transaction([])

  @spec begin_transaction(keyword()) :: {:ok, RouteSnapshot.t()} | {:error, Error.t()}
  def begin_transaction(opts) do
    case Edge.active_route_snapshot(opts) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, :not_found} ->
        {:error,
         Error.new(
           :temporary,
           :route_snapshot_unavailable,
           "recipient route snapshot is unavailable"
         )}

      {:error, :snapshot_expired} ->
        {:error,
         Error.new(:temporary, :route_snapshot_expired, "recipient route snapshot has expired")}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, Error.new(:temporary, :database_unavailable, "edge database is unavailable")}
  end

  @impl Manifold.SMTP.Resolver
  @spec resolve_recipient(String.t(), RouteSnapshot.t()) ::
          {:ok, Route.t()} | {:error, Error.t()}
  def resolve_recipient(address, %RouteSnapshot{} = snapshot) do
    RouteResolver.resolve(snapshot, address)
  end

  @impl Manifold.SMTP.Acceptor
  @spec accept_transport(binary(), map(), [Route.t()]) ::
          {:ok, struct()} | {:error, Error.t()}
  def accept_transport(raw, attrs, routes), do: accept_transport(raw, attrs, routes, [])

  @spec accept_transport(binary(), map(), [Route.t()], keyword()) ::
          {:ok, struct()} | {:error, Error.t()}
  def accept_transport(raw, attrs, routes, opts)
      when is_binary(raw) and is_map(attrs) and is_list(routes) do
    spool_opts = Keyword.get(opts, :spool_opts, [])

    spool_attrs =
      attrs
      |> Map.put(:routes, routes)
      |> Map.put_new(:received_at, DateTime.utc_now())
      |> Map.put_new(:original_recipients, Enum.map(routes, & &1.original_recipient))

    with {:ok, bundle} <- Spool.write_bundle(raw, spool_attrs, spool_opts),
         :ok <- maybe_fault(opts, :after_spool_before_record),
         {:ok, delivery} <- record_bundle(bundle, routes) do
      {:ok, delivery}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, Error.new(:temporary, :database_unavailable, "edge database is unavailable")}
  end

  defp record_bundle(bundle, routes) do
    manifest = bundle.manifest
    snapshot_revision = routes |> List.first() |> Map.fetch!(:snapshot_revision)

    attrs = %{
      ingest_id: bundle.ingest_id,
      snapshot_revision: snapshot_revision,
      peer_ip: manifest.peer_ip,
      helo: manifest.helo,
      envelope_from: manifest.envelope_from,
      received_at: manifest.received_at,
      raw_size: manifest.raw_size,
      raw_sha256: manifest.raw_sha256,
      spool_bundle_path: bundle.path
    }

    recipients =
      Enum.map(routes, fn route ->
        %{
          original_address: route.original_recipient,
          canonical_address: route.canonical_recipient,
          plus_tag: route.plus_tag,
          domain_id: route.domain_id,
          mailbox_ids: route.mailbox_ids
        }
      end)

    case Edge.record_delivery(attrs, recipients) do
      {:ok, delivery} ->
        {:ok, delivery}

      {:error, reason} ->
        {:error,
         Error.new(:temporary, :edge_acceptance_failed, "edge acceptance transaction failed", %{
           reason: inspect(reason)
         })}
    end
  end

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, Error.new(:temporary, point, "injected edge acceptance fault")}
    else
      :ok
    end
  end
end
