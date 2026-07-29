defmodule Manifold.Ingest.Reconciler do
  @moduledoc """
  Reconciles ready spool bundles against committed database state.
  """

  use GenServer
  import Ecto.Query

  alias Manifold.Ingest
  alias Manifold.Ingest.Jobs.ArchiveRawEmail
  alias Manifold.Ingest.Schema.InboundDelivery
  alias Manifold.Mail
  alias Manifold.Repo
  alias Manifold.Storage.Spool

  @interval_ms :timer.seconds(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    send(self(), :reconcile)
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

    partial_retention_seconds =
      Keyword.get(
        opts,
        :partial_retention_seconds,
        Application.get_env(:manifold_ingest, :partial_retention_seconds, 3600)
      )

    Spool.cleanup_partials(root, partial_retention_seconds)
    reconcile_ready_bundles(root, retention_seconds)
    mark_missing_unarchived_bundles(opts)
    reconcile_archived_projections()
    :ok
  end

  defp reconcile_ready_bundles(root, retention_seconds) do
    root
    |> Spool.ready_bundle_paths()
    |> Enum.each(fn path ->
      ingest_id = Path.basename(path)

      case Repo.get_by(InboundDelivery, ingest_id: ingest_id) do
        %InboundDelivery{raw_storage_state: "archived"} = delivery ->
          Ingest.archive_delivery(delivery.id)

        %InboundDelivery{raw_storage_state: "spooled"} = delivery ->
          enqueue_archive_job(delivery.id)

        %InboundDelivery{raw_storage_state: state} = delivery
        when state in ["failed", "missing_spool"] ->
          with {:ok, _restored} <- Ingest.restore_spooled(delivery.id) do
            enqueue_archive_job(delivery.id)
          end

        %InboundDelivery{} ->
          :ok

        nil ->
          case Spool.classify_ready_orphan(path, retention_seconds) do
            :orphan_expired -> Spool.move_ready_to_failed(root, ingest_id, "orphan")
            _ -> :ok
          end
      end
    end)
  end

  defp enqueue_archive_job(delivery_id) do
    Repo.transaction(fn ->
      InboundDelivery
      |> where([delivery], delivery.id == ^delivery_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

      existing_job =
        Oban.Job
        |> where([job], job.worker == ^inspect(ArchiveRawEmail))
        |> where([job], job.state in ~w(available scheduled executing retryable suspended))
        |> where(
          [job],
          fragment("?->>'inbound_delivery_id' = ?", job.args, ^delivery_id)
        )
        |> Repo.one()

      if existing_job do
        existing_job
      else
        %{"inbound_delivery_id" => delivery_id}
        |> ArchiveRawEmail.new()
        |> Repo.insert!()
      end
    end)
  end

  defp mark_missing_unarchived_bundles(opts) do
    stat_fun = Keyword.get(opts, :file_stat_fun, &File.stat/1)

    InboundDelivery
    |> where([d], d.raw_storage_state == "spooled")
    |> Repo.all()
    |> Enum.each(fn delivery ->
      case stat_fun.(delivery.spool_bundle_path) do
        {:ok, _stat} -> :ok
        {:error, :enoent} -> Ingest.mark_missing_spool(delivery)
        {:error, _reason} -> :ok
      end
    end)
  end

  defp reconcile_archived_projections do
    parser_version = Application.get_env(:manifold_mail, :parser_version, 1)
    sanitizer_version = Application.get_env(:manifold_mail, :sanitizer_version, 1)

    incomplete_ids =
      InboundDelivery
      |> where(
        [delivery],
        delivery.raw_storage_state == "archived" and
          delivery.processing_state in ["archived", "parsing"]
      )
      |> select([delivery], delivery.id)
      |> Repo.all()

    stale_ids = Mail.stale_projection_delivery_ids(parser_version, sanitizer_version)

    incomplete_ids
    |> Kernel.++(stale_ids)
    |> Enum.uniq()
    |> Enum.each(&enqueue_projection_job/1)
  end

  defp enqueue_projection_job(delivery_id) do
    case Ingest.ensure_projection_job(delivery_id) do
      {:ok, _job} -> :ok
      {:error, _reason} -> :ok
    end
  end
end
