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
    routes = Enum.map(frozen_routes, &normalize_route/1)

    with :ok <- validate_frozen_routes(bundle, routes) do
      persist_acceptance(bundle, routes, opts)
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(:temporary, :database_unavailable, "database is temporarily unavailable")}
  end

  defp persist_acceptance(bundle, routes, opts) do
    now = DateTime.utc_now()
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
        cleanup_archived_bundle(delivery, opts)

      %InboundDelivery{} = delivery ->
        archive_spooled_delivery(delivery, opts)
    end
  end

  @spec mark_missing_spool(InboundDelivery.t()) :: :ok | {:error, term()}
  def mark_missing_spool(%InboundDelivery{id: delivery_id}) do
    result =
      Repo.transaction(fn ->
        delivery =
          InboundDelivery
          |> where([delivery], delivery.id == ^delivery_id)
          |> lock("FOR UPDATE")
          |> Repo.one!()

        if delivery.raw_storage_state == "spooled" do
          with :ok <-
                 DeliveryState.validate_raw_transition(
                   delivery.raw_storage_state,
                   "missing_spool"
                 ),
               :ok <-
                 DeliveryState.validate_processing_transition(
                   delivery.processing_state,
                   "failed"
                 ),
               {:ok, missing} <-
                 delivery
                 |> InboundDelivery.state_changeset(%{
                   raw_storage_state: "missing_spool",
                   processing_state: "failed",
                   last_error: "ready spool bundle is missing before archival"
                 })
                 |> Repo.update(),
               {:ok, _event} <-
                 MessageEvent.event_changeset(
                   delivery.id,
                   "missing_spool",
                   %{},
                   DateTime.utc_now()
                 )
                 |> Repo.insert() do
            missing
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          delivery
        end
      end)

    case result do
      {:ok, _delivery} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec restore_spooled(Ecto.UUID.t()) :: {:ok, InboundDelivery.t()} | {:error, term()}
  def restore_spooled(delivery_id) do
    Repo.transaction(fn ->
      delivery =
        InboundDelivery
        |> where([delivery], delivery.id == ^delivery_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      case delivery.raw_storage_state do
        "spooled" ->
          delivery

        state ->
          with :ok <- DeliveryState.validate_raw_transition(state, "spooled"),
               :ok <-
                 DeliveryState.validate_processing_transition(
                   delivery.processing_state,
                   "accepted"
                 ),
               {:ok, restored} <-
                 delivery
                 |> InboundDelivery.state_changeset(%{
                   raw_storage_state: "spooled",
                   processing_state: "accepted",
                   last_error: nil
                 })
                 |> Repo.update(),
               {:ok, _event} <-
                 MessageEvent.event_changeset(
                   delivery.id,
                   "spool_restored",
                   %{},
                   DateTime.utc_now()
                 )
                 |> Repo.insert() do
            restored
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp archive_spooled_delivery(delivery, opts) do
    raw_path = Path.join(delivery.spool_bundle_path, "raw.eml")

    with :ok <- verify_spool_file(raw_path, opts),
         {:ok, domain_id} <- first_domain_id(delivery.id),
         key = RawStore.build_key(domain_id, delivery.received_at, delivery.id),
         {:ok, stat} <- ensure_raw_stored(delivery, key, raw_path, opts),
         :ok <- verify_raw_stat(delivery, stat),
         :ok <- maybe_fault(opts, :after_raw_copy_before_update),
         {:ok, archived_delivery} <- commit_archived_state(delivery.id, key),
         :ok <- maybe_fault(opts, :after_archived_state_before_cleanup),
         :ok <- cleanup_archived_bundle(archived_delivery, opts) do
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
    end
  end

  defp ensure_raw_stored(delivery, key, raw_path, opts) do
    raw_store_opts = Keyword.get(opts, :raw_store_opts, [])

    case RawStore.stat(key, raw_store_opts) do
      {:ok, stat} ->
        case verify_raw_stat(delivery, stat) do
          :ok -> {:ok, stat}
          {:error, %Error{}} -> RawStore.put_from_path(key, raw_path, raw_store_opts)
        end

      {:error, reason} when reason in [:enoent, :not_found] ->
        RawStore.put_from_path(key, raw_path, raw_store_opts)

      {:error, reason} ->
        {:error, reason}
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

  defp commit_archived_state(delivery_id, key) do
    Repo.transaction(fn ->
      delivery =
        InboundDelivery
        |> where([delivery], delivery.id == ^delivery_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      case delivery.raw_storage_state do
        "archived" ->
          if delivery.raw_object_key == key do
            delivery
          else
            Repo.rollback(
              Error.new(
                :permanent,
                :invalid_state_transition,
                "delivery is archived under a different raw object key"
              )
            )
          end

        state ->
          with :ok <- DeliveryState.validate_raw_transition(state, "archived"),
               {:ok, archived} <-
                 delivery
                 |> InboundDelivery.state_changeset(%{
                   raw_storage_state: "archived",
                   processing_state: "archived",
                   raw_object_key: key,
                   last_error: nil
                 })
                 |> Repo.update(),
               {:ok, _event} <-
                 delivery.id
                 |> MessageEvent.event_changeset(
                   "archived",
                   %{raw_object_key: key},
                   DateTime.utc_now()
                 )
                 |> Repo.insert() do
            archived
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp cleanup_archived_bundle(%InboundDelivery{} = delivery, opts) do
    raw_store_opts = Keyword.get(opts, :raw_store_opts, [])

    with key when is_binary(key) <- delivery.raw_object_key,
         {:ok, stat} <- RawStore.stat(key, raw_store_opts),
         :ok <- verify_raw_stat(delivery, stat),
         :ok <- remove_spool_bundle_if_present(delivery.spool_bundle_path, opts) do
      :ok
    else
      nil ->
        {:error,
         Error.new(:temporary, :object_store_failed, "archived delivery has no raw object key")}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:temporary, :object_store_failed, "archived raw object verification failed", %{
           reason: inspect(reason)
         })}
    end
  end

  defp remove_spool_bundle_if_present(path, opts) do
    case file_stat(path, opts) do
      {:ok, _stat} -> Spool.remove_ready_bundle(path)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_spool_file(path, opts) do
    case file_stat(path, opts) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :missing_spool}
      {:error, :enoent} -> {:error, :missing_spool}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_stat(path, opts),
    do: Keyword.get(opts, :file_stat_fun, &File.stat/1).(path)

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

  defp validate_frozen_routes(%Bundle{manifest: manifest}, routes) do
    manifest_routes =
      case manifest do
        %{routes: manifest_routes} when is_list(manifest_routes) ->
          Enum.map(manifest_routes, &normalize_route/1)

        _ ->
          []
      end

    original_recipients =
      case manifest do
        %{original_recipients: recipients} when is_list(recipients) -> recipients
        _ -> []
      end

    valid_routes? =
      routes != [] and
        Enum.all?(routes, fn route ->
          non_empty_string?(route.original_recipient) and
            non_empty_string?(route.canonical_recipient) and
            non_empty_string?(route.domain_id) and
            is_list(route.mailbox_ids) and route.mailbox_ids != [] and
            Enum.all?(route.mailbox_ids, &non_empty_string?/1) and
            Enum.uniq(route.mailbox_ids) == route.mailbox_ids
        end)

    manifest_matches? =
      manifest_routes == routes and
        original_recipients == Enum.map(routes, & &1.original_recipient)

    if valid_routes? and manifest_matches? do
      :ok
    else
      {:error,
       Error.new(
         :permanent,
         :invalid_routes,
         "frozen recipient routes are empty, invalid, or differ from the spool manifest"
       )}
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and byte_size(value) > 0

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
