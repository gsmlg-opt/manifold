defmodule Manifold.Ingest do
  @moduledoc """
  Inbound SMTP acceptance, lifecycle, and archival APIs.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Manifold.Accounts
  alias Manifold.Core.{DeliveryState, Error}
  alias Manifold.Ingest.Jobs.ArchiveRawEmail
  alias Manifold.Ingest.Schema.{DeliveryRecipient, InboundDelivery, MailboxEntry, MessageEvent}
  alias Manifold.Ingest.View.DeliveryDetail
  alias Manifold.Repo
  alias Manifold.Storage.{RawStore, Spool}
  alias Manifold.Storage.Spool.Bundle

  @type accept_result :: {:ok, InboundDelivery.t()} | {:error, Error.t()}

  @spec accept_transport(binary(), map(), [map() | struct()], Keyword.t()) :: accept_result()
  def accept_transport(raw, attrs, frozen_routes, opts \\ []) when is_binary(raw) do
    spool_opts = Keyword.get(opts, :spool_opts, [])

    spool_attrs =
      attrs
      |> Map.put(:routes, frozen_routes)
      |> Map.put_new(:received_at, DateTime.utc_now())
      |> Map.put_new(
        :original_recipients,
        Enum.map(frozen_routes, &route_field(&1, :original_recipient))
      )

    with {:ok, bundle} <- Spool.write_bundle(raw, spool_attrs, spool_opts),
         :ok <- maybe_fault(opts, :after_spool_before_accept),
         {:ok, delivery} <- accept(bundle, frozen_routes, opts) do
      {:ok, delivery}
    end
  end

  @spec accept(Bundle.t(), [map() | struct()], Keyword.t()) :: accept_result()
  def accept(%Bundle{} = bundle, frozen_routes, opts \\ []) when is_list(frozen_routes) do
    now = DateTime.utc_now()
    routes = Enum.map(frozen_routes, &normalize_route/1)
    recipient_rows = build_recipient_rows(routes, now)
    mailbox_entry_rows = build_mailbox_entry_rows(routes, now)

    multi =
      Multi.new()
      |> Multi.insert(:delivery, InboundDelivery.acceptance_changeset(%InboundDelivery{}, bundle))
      |> Multi.run(:maybe_fail_after_delivery, fn _repo, _changes ->
        case maybe_fault(opts, :after_delivery_insert_before_commit) do
          :ok -> {:ok, :ok}
          {:error, error} -> {:error, error}
        end
      end)
      |> Multi.insert_all(:delivery_recipients, DeliveryRecipient, fn %{delivery: delivery} ->
        add_delivery_id(recipient_rows, delivery.id)
      end)
      |> Multi.insert_all(
        :mailbox_entries,
        MailboxEntry,
        fn %{delivery: delivery} ->
          add_delivery_id(mailbox_entry_rows, delivery.id)
        end,
        on_conflict: :nothing,
        conflict_target: [:mailbox_id, :inbound_delivery_id]
      )
      |> Multi.insert(:accepted_event, fn %{delivery: delivery} ->
        MessageEvent.event_changeset(
          delivery.id,
          "accepted",
          %{ingest_id: delivery.ingest_id},
          now
        )
      end)
      |> Multi.insert(:archive_job, fn %{delivery: delivery} ->
        ArchiveRawEmail.new(%{"inbound_delivery_id" => delivery.id})
      end)

    case Repo.transaction(multi) do
      {:ok, %{delivery: delivery}} ->
        :telemetry.execute(
          [:manifold, :ingest, :accept, :stop],
          %{raw_size: delivery.raw_size},
          %{
            ingest_id: delivery.ingest_id,
            delivery_id: delivery.id
          }
        )

        {:ok, delivery}

      {:error, _step, %Error{} = error, _changes} ->
        {:error, error}

      {:error, _step, reason, _changes} ->
        {:error,
         Error.new(:temporary, :acceptance_failed, "acceptance transaction failed", %{
           reason: inspect(reason)
         })}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(:temporary, :database_unavailable, "database is temporarily unavailable")}
  end

  @spec list_inbound_deliveries() :: [InboundDelivery.t()]
  def list_inbound_deliveries do
    InboundDelivery
    |> order_by([d], desc: d.received_at)
    |> limit(100)
    |> Repo.all()
  end

  @spec get_inbound_delivery!(Ecto.UUID.t()) :: InboundDelivery.t()
  def get_inbound_delivery!(id), do: Repo.get!(InboundDelivery, id)

  @spec get_delivery_detail!(Ecto.UUID.t()) :: DeliveryDetail.t()
  def get_delivery_detail!(id) do
    delivery =
      InboundDelivery
      |> preload([:delivery_recipients, :mailbox_entries, :message_events])
      |> Repo.get!(id)

    mailbox_ids =
      delivery.delivery_recipients
      |> Enum.map(& &1.mailbox_id)
      |> Enum.uniq()

    mailboxes =
      Enum.map(mailbox_ids, fn mailbox_id ->
        mailbox = Accounts.get_mailbox!(mailbox_id)

        %{
          id: mailbox.id,
          local_part: mailbox.local_part,
          domain_id: mailbox.domain_id,
          display_name: mailbox.display_name
        }
      end)

    %DeliveryDetail{
      delivery: delivery,
      recipients: delivery.delivery_recipients,
      mailboxes: mailboxes,
      events: delivery.message_events
    }
  end

  @spec archive_delivery(Ecto.UUID.t(), Keyword.t()) :: :ok | {:error, Error.t()}
  def archive_delivery(delivery_id, opts \\ []) do
    case Repo.get(InboundDelivery, delivery_id) do
      nil ->
        {:error, Error.new(:permanent, :not_found, "delivery not found")}

      %InboundDelivery{raw_storage_state: "archived"} = delivery ->
        cleanup_archived_bundle(delivery)

      %InboundDelivery{} = delivery ->
        archive_spooled_delivery(delivery, opts)
    end
  end

  @spec mark_missing_spool(InboundDelivery.t()) :: :ok | {:error, Ecto.Changeset.t()}
  def mark_missing_spool(%InboundDelivery{} = delivery) do
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> Multi.update(
        :delivery,
        InboundDelivery.state_changeset(delivery, %{
          raw_storage_state: "missing_spool",
          processing_state: "failed",
          last_error: "ready spool bundle is missing before archival"
        })
      )
      |> Multi.insert(
        :event,
        MessageEvent.event_changeset(delivery.id, "missing_spool", %{}, now)
      )

    case Repo.transaction(multi) do
      {:ok, _} -> :ok
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  defp archive_spooled_delivery(delivery, opts) do
    raw_path = Path.join(delivery.spool_bundle_path, "raw.eml")

    with true <- File.exists?(raw_path) || {:error, :missing_spool},
         {:ok, domain_id} <- first_domain_id(delivery.id),
         key = RawStore.build_key(domain_id, delivery.received_at, delivery.id),
         {:ok, stat} <- ensure_raw_stored(key, raw_path, opts),
         :ok <- verify_raw_stat(delivery, stat),
         :ok <- maybe_fault(opts, :after_raw_copy_before_update),
         {:ok, _changes} <- commit_archived_state(delivery, key),
         :ok <- maybe_fault(opts, :after_archived_state_before_cleanup),
         :ok <- cleanup_archived_bundle(%{delivery | raw_storage_state: "archived"}) do
      :telemetry.execute([:manifold, :ingest, :archive, :stop], %{raw_size: delivery.raw_size}, %{
        delivery_id: delivery.id,
        ingest_id: delivery.ingest_id
      })

      :ok
    else
      {:error, :missing_spool} ->
        :ok = mark_missing_spool(delivery)

        {:error,
         Error.new(:permanent, :missing_spool, "ready spool bundle is missing before archival")}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:temporary, :object_store_failed, "raw object archival failed", %{
           reason: inspect(reason)
         })}

      false ->
        :ok = mark_missing_spool(delivery)

        {:error,
         Error.new(:permanent, :missing_spool, "ready spool bundle is missing before archival")}
    end
  end

  defp ensure_raw_stored(key, raw_path, opts) do
    case RawStore.stat(key) do
      {:ok, stat} ->
        {:ok, stat}

      {:error, _reason} ->
        RawStore.put_from_path(key, raw_path, Keyword.get(opts, :raw_store_opts, []))
    end
  end

  defp verify_raw_stat(delivery, %{size: size, sha256: sha256}) do
    cond do
      size != delivery.raw_size ->
        {:error, Error.new(:temporary, :object_store_failed, "archived raw size mismatch")}

      sha256 && sha256 != delivery.raw_sha256 ->
        {:error, Error.new(:temporary, :object_store_failed, "archived raw SHA-256 mismatch")}

      true ->
        :ok
    end
  end

  defp commit_archived_state(delivery, key) do
    now = DateTime.utc_now()

    with :ok <- DeliveryState.validate_raw_transition(delivery.raw_storage_state, "archived") do
      Multi.new()
      |> Multi.update(
        :delivery,
        InboundDelivery.state_changeset(delivery, %{
          raw_storage_state: "archived",
          processing_state: "archived",
          raw_object_key: key,
          last_error: nil
        })
      )
      |> Multi.insert(
        :event,
        MessageEvent.event_changeset(delivery.id, "archived", %{raw_object_key: key}, now)
      )
      |> Repo.transaction()
    end
  end

  defp cleanup_archived_bundle(%InboundDelivery{spool_bundle_path: path}) do
    case File.exists?(path) do
      true -> Spool.remove_ready_bundle(path)
      false -> :ok
    end
  end

  defp cleanup_archived_bundle(%{spool_bundle_path: path}) do
    case File.exists?(path) do
      true -> Spool.remove_ready_bundle(path)
      false -> :ok
    end
  end

  defp first_domain_id(delivery_id) do
    DeliveryRecipient
    |> where([r], r.inbound_delivery_id == ^delivery_id)
    |> order_by([r], asc: r.id)
    |> select([r], r.mailbox_id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, Error.new(:temporary, :object_store_failed, "delivery has no recipients")}
      mailbox_id -> Accounts.mailbox_domain_id(mailbox_id)
    end
  end

  defp build_recipient_rows(routes, now) do
    Enum.flat_map(routes, fn route ->
      Enum.map(route.mailbox_ids, fn mailbox_id ->
        %{
          id: Ecto.UUID.generate(),
          original_address: route.original_recipient,
          canonical_address: route.canonical_recipient,
          plus_tag: route.plus_tag,
          mailbox_id: mailbox_id,
          inserted_at: now,
          updated_at: now
        }
      end)
    end)
  end

  defp build_mailbox_entry_rows(routes, now) do
    routes
    |> Enum.flat_map(fn route ->
      Enum.map(route.mailbox_ids, &{&1, route.original_recipient})
    end)
    |> Enum.reduce(%{}, fn {mailbox_id, original_recipient}, acc ->
      Map.put_new(acc, mailbox_id, original_recipient)
    end)
    |> Enum.map(fn {mailbox_id, original_recipient} ->
      %{
        id: Ecto.UUID.generate(),
        mailbox_id: mailbox_id,
        original_recipient: original_recipient,
        status: "unread",
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  defp add_delivery_id(rows, delivery_id),
    do: Enum.map(rows, &Map.put(&1, :inbound_delivery_id, delivery_id))

  defp normalize_route(%_{} = struct), do: struct |> Map.from_struct() |> normalize_route()

  defp normalize_route(map) when is_map(map) do
    %{
      original_recipient: route_field(map, :original_recipient),
      canonical_recipient: route_field(map, :canonical_recipient),
      plus_tag: route_field(map, :plus_tag),
      domain_id: route_field(map, :domain_id),
      mailbox_ids: route_field(map, :mailbox_ids) || []
    }
  end

  defp route_field(map, field) when is_map(map) do
    Map.get(map, field) || Map.get(map, Atom.to_string(field))
  end

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, Error.new(:temporary, point, "injected ingest fault")}
    else
      :ok
    end
  end
end
