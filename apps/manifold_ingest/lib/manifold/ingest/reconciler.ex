defmodule Manifold.Ingest.Reconciler do
  @moduledoc """
  Reconciles ready spool bundles against committed database state.
  """

  use GenServer
  import Ecto.Query

  alias Manifold.Ingest
  alias Manifold.Ingest.Jobs.ArchiveRawEmail
  alias Manifold.Ingest.Schema.InboundDelivery
  alias Manifold.Repo
  alias Manifold.Storage.Spool

  @interval_ms :timer.seconds(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :reconcile, Keyword.get(opts, :interval_ms, @interval_ms))
    {:ok, opts}
  end

  @impl true
  def handle_info(:reconcile, opts) do
    reconcile_once(opts)
    Process.send_after(self(), :reconcile, Keyword.get(opts, :interval_ms, @interval_ms))
    {:noreply, opts}
  end

  @spec reconcile_once(Keyword.t()) :: :ok
  def reconcile_once(opts \\ []) do
    root = Keyword.get(opts, :root, Spool.spool_root())

    retention_seconds =
      Keyword.get(
        opts,
        :orphan_retention_seconds,
        Application.get_env(:manifold_ingest, :orphan_retention_seconds, 3600)
      )

    reconcile_ready_bundles(root, retention_seconds)
    mark_missing_unarchived_bundles()
    :ok
  end

  defp reconcile_ready_bundles(root, retention_seconds) do
    root
    |> Spool.ready_bundle_paths()
    |> Enum.each(fn path ->
      ingest_id = Path.basename(path)

      case Repo.get_by(InboundDelivery, ingest_id: ingest_id) do
        %InboundDelivery{raw_storage_state: "archived"} = delivery ->
          if File.exists?(delivery.spool_bundle_path),
            do: Spool.remove_ready_bundle(delivery.spool_bundle_path)

        %InboundDelivery{} = delivery ->
          ArchiveRawEmail.new(%{"inbound_delivery_id" => delivery.id}) |> Oban.insert()

        nil ->
          case Spool.classify_ready_orphan(path, retention_seconds) do
            :orphan_expired -> Spool.move_ready_to_failed(root, ingest_id, "orphan")
            _ -> :ok
          end
      end
    end)
  end

  defp mark_missing_unarchived_bundles do
    InboundDelivery
    |> where([d], d.raw_storage_state != "archived")
    |> Repo.all()
    |> Enum.each(fn delivery ->
      unless File.exists?(delivery.spool_bundle_path) do
        Ingest.mark_missing_spool(delivery)
      end
    end)
  end
end
