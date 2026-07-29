defmodule Manifold.Edge.Reconciler do
  @moduledoc """
  Repairs durable edge spool/database crash boundaries.
  """

  use GenServer

  import Ecto.Query

  alias Manifold.Edge.Repo
  alias Manifold.Edge.Schema.{Delivery, DeliveryEvent, Nonce}
  alias Manifold.Storage.Spool
  alias Manifold.Storage.Spool.Manifest

  @default_interval_ms 60_000
  @missing_spool_error "ready spool bundle is missing"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, Spool.spool_root())
    retention = Keyword.get(opts, :orphan_retention_seconds, 3600)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stat_fun = Keyword.get(opts, :stat_fun, &File.stat/1)

    prune_expired_nonces(now)
    cleanup_acknowledged(stat_fun)
    restore_missing_ready(stat_fun)
    mark_missing_ready(stat_fun)
    classify_orphans(root, retention)
    :ok
  end

  @impl GenServer
  def init(opts) do
    send(self(), :reconcile)
    {:ok, %{interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms)}}
  end

  @impl GenServer
  def handle_info(:reconcile, state) do
    :ok = run()
    Process.send_after(self(), :reconcile, state.interval_ms)
    {:noreply, state}
  end

  defp cleanup_acknowledged(stat_fun) do
    Delivery
    |> where([delivery], delivery.state == "acknowledged")
    |> Repo.all()
    |> Enum.each(fn delivery ->
      case stat_fun.(delivery.spool_bundle_path) do
        {:ok, %{type: :directory}} ->
          case verify_bundle(delivery) do
            :ok -> cleanup_acknowledged_bundle(delivery)
            {:error, reason} -> record_cleanup_error(delivery, reason)
          end

        {:error, :enoent} ->
          cleanup_acknowledged_bundle(delivery)

        {:error, reason} ->
          record_cleanup_error(delivery, inspect(reason))

        {:ok, _not_directory} ->
          record_cleanup_error(delivery, "bundle path is not a directory")
      end
    end)
  end

  defp cleanup_acknowledged_bundle(delivery) do
    case Spool.cleanup_ready_bundle(delivery.spool_bundle_path) do
      :ok -> :ok
      {:error, reason} -> record_cleanup_error(delivery, inspect(reason))
    end
  end

  defp record_cleanup_error(delivery, reason) do
    delivery
    |> Delivery.operational_error_changeset(%{
      last_error: "acknowledged spool cleanup failed: #{reason}"
    })
    |> Repo.update()
  end

  defp prune_expired_nonces(now) do
    Nonce
    |> where([nonce], nonce.expires_at <= ^now)
    |> Repo.delete_all()

    :ok
  end

  defp mark_missing_ready(stat_fun) do
    Delivery
    |> where([delivery], delivery.state == "ready")
    |> Repo.all()
    |> Enum.each(fn delivery ->
      case stat_fun.(delivery.spool_bundle_path) do
        {:ok, %{type: :directory}} ->
          clear_stat_error(delivery.id)

        {:error, :enoent} ->
          fail_missing_ready_locked(delivery.id, stat_fun)

        {:error, reason} ->
          record_stat_error(delivery.id, reason)

        {:ok, _not_directory} ->
          fail_missing_ready_locked(delivery.id, stat_fun)
      end
    end)
  end

  defp restore_missing_ready(stat_fun) do
    Delivery
    |> where(
      [delivery],
      delivery.state == "failed" and delivery.last_error == ^@missing_spool_error
    )
    |> select([delivery], delivery.id)
    |> Repo.all()
    |> Enum.each(&restore_missing_ready_locked(&1, stat_fun))
  end

  defp restore_missing_ready_locked(delivery_id, stat_fun) do
    Repo.transaction(fn ->
      delivery = locked_delivery(delivery_id)

      if delivery.state == "failed" and delivery.last_error == @missing_spool_error and
           bundle_directory?(stat_fun, delivery.spool_bundle_path) and
           verify_bundle(delivery) == :ok do
        {:ok, _restored} =
          delivery
          |> Delivery.recovery_changeset(%{state: "ready", last_error: nil})
          |> Repo.update()

        insert_event!(delivery.id, "spool_restored", %{})
      end
    end)
  end

  defp fail_missing_ready_locked(delivery_id, stat_fun) do
    Repo.transaction(fn ->
      delivery = locked_delivery(delivery_id)

      if delivery.state == "ready" do
        case stat_fun.(delivery.spool_bundle_path) do
          {:ok, %{type: :directory}} ->
            :ok

          {:error, :enoent} ->
            fail_delivery_for_missing_spool(delivery)

          {:error, reason} ->
            update_stat_error(delivery, reason)

          {:ok, _not_directory} ->
            fail_delivery_for_missing_spool(delivery)
        end
      end
    end)
  end

  defp fail_delivery_for_missing_spool(delivery) do
    {:ok, _failed} =
      delivery
      |> Delivery.failure_changeset(%{
        state: "failed",
        last_error: @missing_spool_error
      })
      |> Repo.update()

    insert_event!(delivery.id, "missing_spool", %{})
  end

  defp record_stat_error(delivery_id, reason) do
    Delivery
    |> where([delivery], delivery.id == ^delivery_id and delivery.state == "ready")
    |> Repo.update_all(set: [last_error: stat_error(reason), updated_at: DateTime.utc_now()])

    :ok
  end

  defp clear_stat_error(delivery_id) do
    Delivery
    |> where(
      [delivery],
      delivery.id == ^delivery_id and delivery.state == "ready" and
        like(delivery.last_error, "ready spool status check failed:%")
    )
    |> Repo.update_all(set: [last_error: nil, updated_at: DateTime.utc_now()])

    :ok
  end

  defp update_stat_error(delivery, reason) do
    {:ok, _delivery} =
      delivery
      |> Delivery.operational_error_changeset(%{last_error: stat_error(reason)})
      |> Repo.update()
  end

  defp stat_error(reason), do: "ready spool status check failed: #{inspect(reason)}"

  defp bundle_directory?(stat_fun, path) do
    case stat_fun.(path) do
      {:ok, %{type: :directory}} -> true
      _missing_or_unavailable -> false
    end
  end

  defp locked_delivery(delivery_id) do
    Repo.one!(
      from(delivery in Delivery,
        where: delivery.id == ^delivery_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp insert_event!(delivery_id, event_type, metadata) do
    %DeliveryEvent{}
    |> DeliveryEvent.changeset(%{
      delivery_id: delivery_id,
      event_type: event_type,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp classify_orphans(root, retention) do
    known_ingest_ids =
      Delivery
      |> select([delivery], delivery.ingest_id)
      |> Repo.all()
      |> MapSet.new()

    root
    |> Spool.ready_bundle_paths()
    |> Enum.each(fn path ->
      ingest_id = Path.basename(path)

      if not MapSet.member?(known_ingest_ids, ingest_id) and
           Spool.classify_ready_orphan(path, retention) == :orphan_expired do
        _move_result = Spool.move_ready_to_failed(root, ingest_id, "orphan")
      end
    end)
  end

  defp verify_bundle(delivery) do
    raw_path = Path.join(delivery.spool_bundle_path, "raw.eml")

    with {:ok, manifest} <- Spool.read_manifest(delivery.spool_bundle_path),
         true <- manifest.ingest_id == delivery.ingest_id,
         true <- manifest.raw_size == delivery.raw_size,
         true <- manifest.raw_sha256 == delivery.raw_sha256,
         {:ok, stat} <- File.stat(raw_path),
         true <- stat.size == delivery.raw_size,
         {:ok, digest} <- Manifest.sha256_file(raw_path),
         true <- digest == delivery.raw_sha256 do
      :ok
    else
      _invalid -> {:error, "raw size or SHA-256 mismatch"}
    end
  end
end
