defmodule Manifold.Edge do
  @moduledoc """
  Edge-only persistence APIs for route snapshots and durably spooled deliveries.
  """

  import Ecto.Query

  alias Manifold.Edge.Repo
  alias Manifold.Edge.RouteSnapshot
  alias Manifold.Edge.RouteSnapshot.Route, as: SnapshotRoute

  alias Manifold.Edge.Schema.{
    Delivery,
    DeliveryEvent,
    DeliveryRecipient,
    InstalledRoute,
    InstalledRouteSnapshot,
    Nonce
  }

  @snapshot_schema_version 1
  @snapshot_install_lock 6_147_832_241
  @default_pending_limit 100
  @max_pending_limit 1_000

  @type error_reason ::
          :acknowledgement_conflict
          | :delivery_conflict
          | :digest_mismatch
          | :expired_nonce
          | :invalid_acknowledgement
          | :invalid_delivery
          | :invalid_nonce
          | :invalid_snapshot
          | :not_found
          | :replayed_nonce
          | :snapshot_conflict
          | :snapshot_expired
          | :snapshot_rollback
          | :unsupported_snapshot_version

  @spec install_route_snapshot(RouteSnapshot.t(), keyword()) ::
          {:ok, InstalledRouteSnapshot.t()} | {:error, error_reason()}
  def install_route_snapshot(%RouteSnapshot{} = snapshot, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_snapshot(snapshot, now) do
      transact(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [@snapshot_install_lock])

        case latest_snapshot() do
          nil ->
            insert_snapshot(snapshot, now)

          %InstalledRouteSnapshot{revision: revision} when snapshot.revision < revision ->
            Repo.rollback(:snapshot_rollback)

          %InstalledRouteSnapshot{revision: revision, digest: digest} = installed
          when snapshot.revision == revision ->
            if snapshot.digest == digest do
              refresh_snapshot_validity(installed, snapshot, now)
            else
              Repo.rollback(:snapshot_conflict)
            end

          %InstalledRouteSnapshot{} ->
            insert_snapshot(snapshot, now)
        end
      end)
    end
  end

  @spec active_route_snapshot(keyword()) ::
          {:ok, RouteSnapshot.t()} | {:error, :not_found | :snapshot_expired}
  def active_route_snapshot(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Repo.one(from(snapshot in InstalledRouteSnapshot, where: snapshot.active)) do
      nil ->
        {:error, :not_found}

      %InstalledRouteSnapshot{} = installed ->
        if DateTime.compare(installed.expires_at, now) == :gt do
          installed = Repo.preload(installed, :routes)
          {:ok, to_route_snapshot(installed)}
        else
          {:error, :snapshot_expired}
        end
    end
  end

  @spec record_delivery(map(), [map()], keyword()) ::
          {:ok, Delivery.t()} | {:error, error_reason()}
  def record_delivery(attrs, recipients, opts \\ [])
      when is_map(attrs) and is_list(recipients) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_recipients(recipients),
         {:ok, revision} <- fetch_integer(attrs, :snapshot_revision) do
      transact(fn ->
        snapshot =
          Repo.one(
            from(snapshot in InstalledRouteSnapshot,
              where: snapshot.revision == ^revision
            )
          ) || Repo.rollback(:invalid_delivery)

        case existing_delivery(attrs) do
          nil -> insert_delivery(snapshot, attrs, recipients, now)
          %Delivery{} = delivery -> verify_existing_delivery(delivery, attrs, recipients)
        end
      end)
    else
      {:error, _reason} -> {:error, :invalid_delivery}
    end
  end

  @spec list_pending_deliveries(keyword()) :: [Delivery.t()]
  def list_pending_deliveries(opts \\ []) do
    limit =
      opts
      |> Keyword.get(:limit, @default_pending_limit)
      |> normalize_limit()

    Delivery
    |> where([delivery], delivery.state == "ready")
    |> order_by([delivery], asc: delivery.received_at, asc: delivery.id)
    |> limit(^limit)
    |> preload([:recipients, :events])
    |> Repo.all()
  end

  @spec get_delivery(Ecto.UUID.t()) :: {:ok, Delivery.t()} | {:error, :not_found}
  def get_delivery(delivery_id) when is_binary(delivery_id) do
    case Repo.get(Delivery, delivery_id) do
      nil -> {:error, :not_found}
      delivery -> {:ok, Repo.preload(delivery, [:recipients, :events])}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @spec acknowledge_delivery(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Delivery.t()} | {:error, error_reason()}
  def acknowledge_delivery(delivery_id, acknowledgement, opts \\ [])
      when is_binary(delivery_id) and is_map(acknowledgement) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, local_delivery_id} <- fetch_binary(acknowledgement, :local_delivery_id),
         {:ok, raw_sha256} <- fetch_binary(acknowledgement, :raw_sha256) do
      transact(fn ->
        delivery =
          Repo.one(
            from(delivery in Delivery,
              where: delivery.id == ^delivery_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        acknowledge_locked(delivery, local_delivery_id, raw_sha256, now)
      end)
    else
      {:error, _reason} -> {:error, :invalid_acknowledgement}
    end
  end

  @doc """
  Isolates a delivery that the local installation permanently rejected.

  The edge retains the spool bundle for operator recovery. Repeating the same
  failure report is idempotent.
  """
  @spec fail_delivery(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Delivery.t()} | {:error, error_reason()}
  def fail_delivery(delivery_id, failure, opts \\ [])
      when is_binary(delivery_id) and is_map(failure) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, raw_sha256} <- fetch_binary(failure, :raw_sha256),
         {:ok, reason} <- fetch_binary(failure, :reason),
         true <- valid_failure_reason?(reason) do
      transact(fn ->
        delivery =
          Repo.one(
            from(delivery in Delivery,
              where: delivery.id == ^delivery_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        fail_locked(delivery, raw_sha256, reason, now)
      end)
    else
      _invalid -> {:error, :invalid_delivery}
    end
  end

  @spec claim_nonce(String.t(), String.t(), DateTime.t(), keyword()) ::
          :ok | {:error, error_reason()}
  def claim_nonce(key_id, nonce, %DateTime{} = expires_at, opts \\ [])
      when is_binary(key_id) and is_binary(nonce) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    cond do
      key_id == "" or byte_size(key_id) > 255 or nonce == "" or byte_size(nonce) > 1_024 ->
        {:error, :invalid_nonce}

      DateTime.compare(expires_at, now) != :gt ->
        {:error, :expired_nonce}

      true ->
        nonce_digest =
          nonce
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        changeset =
          Nonce.claim_changeset(%Nonce{}, %{
            key_id: key_id,
            nonce_digest: nonce_digest,
            expires_at: expires_at,
            claimed_at: now
          })

        case Repo.insert(changeset) do
          {:ok, _nonce} -> :ok
          {:error, changeset} -> classify_nonce_error(changeset)
        end
    end
  end

  defp validate_snapshot(snapshot, now) do
    cond do
      snapshot.schema_version != @snapshot_schema_version ->
        {:error, :unsupported_snapshot_version}

      not (is_integer(snapshot.revision) and snapshot.revision >= 0) ->
        {:error, :invalid_snapshot}

      not valid_digest?(snapshot.digest) ->
        {:error, :invalid_snapshot}

      not valid_datetime?(snapshot.generated_at) or not valid_datetime?(snapshot.expires_at) ->
        {:error, :invalid_snapshot}

      DateTime.compare(snapshot.expires_at, snapshot.generated_at) != :gt ->
        {:error, :invalid_snapshot}

      DateTime.compare(snapshot.expires_at, now) != :gt ->
        {:error, :snapshot_expired}

      not valid_routes?(snapshot.routes) ->
        {:error, :invalid_snapshot}

      true ->
        :ok
    end
  end

  defp valid_routes?(routes) when is_list(routes) do
    canonical_addresses = Enum.map(routes, & &1.canonical_address)

    Enum.all?(routes, fn
      %SnapshotRoute{
        canonical_address: address,
        domain_id: domain_id,
        mailbox_ids: mailbox_ids,
        plus_addressing_enabled: plus_enabled
      } ->
        is_binary(address) and address != "" and is_binary(domain_id) and domain_id != "" and
          is_list(mailbox_ids) and mailbox_ids != [] and
          Enum.all?(mailbox_ids, &(is_binary(&1) and &1 != "")) and is_boolean(plus_enabled)

      _route ->
        false
    end) and Enum.uniq(canonical_addresses) == canonical_addresses
  end

  defp valid_routes?(_routes), do: false

  defp insert_snapshot(snapshot, now) do
    Repo.update_all(
      from(installed in InstalledRouteSnapshot, where: installed.active),
      set: [active: false, updated_at: now]
    )

    attrs = %{
      schema_version: snapshot.schema_version,
      revision: snapshot.revision,
      digest: snapshot.digest,
      generated_at: snapshot.generated_at,
      expires_at: snapshot.expires_at,
      installed_at: now,
      active: true
    }

    installed =
      case Repo.insert(InstalledRouteSnapshot.install_changeset(%InstalledRouteSnapshot{}, attrs)) do
        {:ok, installed} -> installed
        {:error, _changeset} -> Repo.rollback(:invalid_snapshot)
      end

    snapshot.routes
    |> Enum.with_index()
    |> Enum.each(fn {route, position} ->
      route_attrs = %{
        route_snapshot_id: installed.id,
        position: position,
        canonical_address: route.canonical_address,
        domain_id: route.domain_id,
        mailbox_ids: route.mailbox_ids,
        plus_addressing_enabled: route.plus_addressing_enabled
      }

      case Repo.insert(InstalledRoute.install_changeset(%InstalledRoute{}, route_attrs)) do
        {:ok, _route} -> :ok
        {:error, _changeset} -> Repo.rollback(:invalid_snapshot)
      end
    end)

    Repo.preload(installed, :routes)
  end

  defp refresh_snapshot_validity(installed, snapshot, now) do
    newer? =
      DateTime.compare(snapshot.generated_at, installed.generated_at) in [:eq, :gt] and
        DateTime.compare(snapshot.expires_at, installed.expires_at) == :gt

    if newer? do
      attrs = %{
        schema_version: installed.schema_version,
        revision: installed.revision,
        digest: installed.digest,
        generated_at: snapshot.generated_at,
        expires_at: snapshot.expires_at,
        installed_at: now,
        active: installed.active
      }

      case installed
           |> InstalledRouteSnapshot.install_changeset(attrs)
           |> Repo.update() do
        {:ok, refreshed} -> Repo.preload(refreshed, :routes, force: true)
        {:error, _changeset} -> Repo.rollback(:invalid_snapshot)
      end
    else
      Repo.preload(installed, :routes)
    end
  end

  defp latest_snapshot do
    Repo.one(
      from(snapshot in InstalledRouteSnapshot, order_by: [desc: snapshot.revision], limit: 1)
    )
  end

  defp to_route_snapshot(installed) do
    %RouteSnapshot{
      schema_version: installed.schema_version,
      revision: installed.revision,
      digest: installed.digest,
      generated_at: installed.generated_at,
      expires_at: installed.expires_at,
      routes:
        Enum.map(installed.routes, fn route ->
          %SnapshotRoute{
            canonical_address: route.canonical_address,
            domain_id: route.domain_id,
            mailbox_ids: route.mailbox_ids,
            plus_addressing_enabled: route.plus_addressing_enabled
          }
        end)
    }
  end

  defp validate_recipients([]), do: {:error, :missing_recipients}

  defp validate_recipients(recipients) do
    if Enum.all?(recipients, &valid_recipient?/1) do
      :ok
    else
      {:error, :invalid_recipient}
    end
  end

  defp valid_recipient?(recipient) do
    with {:ok, original_address} <- fetch_binary(recipient, :original_address),
         {:ok, canonical_address} <- fetch_binary(recipient, :canonical_address),
         {:ok, domain_id} <- fetch_binary(recipient, :domain_id),
         {:ok, mailbox_ids} <- fetch_value(recipient, :mailbox_ids) do
      original_address != "" and canonical_address != "" and domain_id != "" and
        is_list(mailbox_ids) and mailbox_ids != [] and
        Enum.all?(mailbox_ids, &(is_binary(&1) and &1 != ""))
    else
      _error -> false
    end
  end

  defp existing_delivery(attrs) do
    case fetch_binary(attrs, :ingest_id) do
      {:ok, ingest_id} -> Repo.get_by(Delivery, ingest_id: ingest_id)
      {:error, _reason} -> nil
    end
  end

  defp insert_delivery(snapshot, attrs, recipients, now) do
    delivery_attrs =
      attrs
      |> Map.new()
      |> Map.put(:route_snapshot_id, snapshot.id)
      |> Map.put(:snapshot_revision, snapshot.revision)
      |> Map.put(:state, "ready")

    delivery =
      case Repo.insert(Delivery.acceptance_changeset(%Delivery{}, delivery_attrs)) do
        {:ok, delivery} -> delivery
        {:error, _changeset} -> Repo.rollback(:invalid_delivery)
      end

    recipients
    |> Enum.with_index()
    |> Enum.each(fn {recipient, position} ->
      recipient_attrs =
        recipient
        |> Map.new()
        |> Map.put(:delivery_id, delivery.id)
        |> Map.put(:position, position)

      case Repo.insert(
             DeliveryRecipient.acceptance_changeset(%DeliveryRecipient{}, recipient_attrs)
           ) do
        {:ok, _recipient} -> :ok
        {:error, _changeset} -> Repo.rollback(:invalid_delivery)
      end
    end)

    insert_event(delivery.id, "accepted", %{snapshot_revision: snapshot.revision}, now)
    Repo.preload(delivery, [:recipients, :events])
  end

  defp verify_existing_delivery(delivery, attrs, recipients) do
    delivery = Repo.preload(delivery, [:recipients, :events])

    if delivery_identity(delivery) == delivery_identity(attrs) and
         recipient_identities(delivery.recipients) == recipient_identities(recipients) do
      delivery
    else
      Repo.rollback(:delivery_conflict)
    end
  end

  defp delivery_identity(%Delivery{} = delivery) do
    {
      delivery.snapshot_revision,
      delivery.peer_ip,
      delivery.helo,
      delivery.envelope_from,
      delivery.received_at,
      delivery.raw_size,
      delivery.raw_sha256,
      delivery.spool_bundle_path
    }
  end

  defp delivery_identity(attrs) when is_map(attrs) do
    fields = [
      :snapshot_revision,
      :peer_ip,
      :helo,
      :envelope_from,
      :received_at,
      :raw_size,
      :raw_sha256,
      :spool_bundle_path
    ]

    fields
    |> Enum.map(fn field ->
      case fetch_value(attrs, field) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
    |> List.to_tuple()
  end

  defp recipient_identities(recipients) do
    recipients
    |> Enum.with_index()
    |> Enum.map(fn
      {%DeliveryRecipient{} = recipient, position} ->
        {
          position,
          recipient.original_address,
          recipient.canonical_address,
          recipient.plus_tag,
          recipient.domain_id,
          recipient.mailbox_ids
        }

      {recipient, position} ->
        {
          position,
          value_or_nil(recipient, :original_address),
          value_or_nil(recipient, :canonical_address),
          value_or_nil(recipient, :plus_tag),
          value_or_nil(recipient, :domain_id),
          value_or_nil(recipient, :mailbox_ids)
        }
    end)
  end

  defp acknowledge_locked(delivery, local_delivery_id, raw_sha256, now) do
    cond do
      delivery.raw_sha256 != raw_sha256 ->
        Repo.rollback(:digest_mismatch)

      delivery.state == "acknowledged" and delivery.local_delivery_id == local_delivery_id ->
        Repo.preload(delivery, [:recipients, :events])

      delivery.state == "acknowledged" ->
        Repo.rollback(:acknowledgement_conflict)

      delivery.state != "ready" ->
        Repo.rollback(:acknowledgement_conflict)

      true ->
        changeset =
          Delivery.acknowledgement_changeset(delivery, %{
            state: "acknowledged",
            local_delivery_id: local_delivery_id,
            acknowledged_at: now
          })

        acknowledged =
          case Repo.update(changeset) do
            {:ok, acknowledged} -> acknowledged
            {:error, _changeset} -> Repo.rollback(:invalid_acknowledgement)
          end

        insert_event(
          delivery.id,
          "acknowledged",
          %{local_delivery_id: local_delivery_id},
          now
        )

        Repo.preload(acknowledged, [:recipients, :events], force: true)
    end
  end

  defp fail_locked(delivery, raw_sha256, reason, now) do
    last_error = "local import failed: " <> reason

    cond do
      delivery.raw_sha256 != raw_sha256 ->
        Repo.rollback(:digest_mismatch)

      delivery.state == "failed" ->
        Repo.preload(delivery, [:recipients, :events])

      delivery.state != "ready" ->
        Repo.rollback(:delivery_conflict)

      true ->
        failed =
          delivery
          |> Delivery.failure_changeset(%{state: "failed", last_error: last_error})
          |> Repo.update!()

        insert_event(delivery.id, "import_failed", %{reason: reason}, now)
        Repo.preload(failed, [:recipients, :events], force: true)
    end
  end

  defp insert_event(delivery_id, event_type, metadata, occurred_at) do
    changeset =
      DeliveryEvent.changeset(%DeliveryEvent{}, %{
        delivery_id: delivery_id,
        event_type: event_type,
        metadata: metadata,
        occurred_at: occurred_at
      })

    case Repo.insert(changeset) do
      {:ok, event} -> event
      {:error, _changeset} -> Repo.rollback(:invalid_delivery)
    end
  end

  defp fetch_integer(map, field) do
    case fetch_value(map, field) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      _other -> {:error, field}
    end
  end

  defp fetch_binary(map, field) do
    case fetch_value(map, field) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _other -> {:error, field}
    end
  end

  defp fetch_value(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(field))
    end
  end

  defp value_or_nil(map, field) do
    case fetch_value(map, field) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp normalize_limit(limit) when is_integer(limit) do
    limit
    |> max(1)
    |> min(@max_pending_limit)
  end

  defp normalize_limit(_limit), do: @default_pending_limit

  defp classify_nonce_error(changeset) do
    if Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
         metadata[:constraint] == :unique
       end) do
      {:error, :replayed_nonce}
    else
      {:error, :invalid_nonce}
    end
  end

  defp valid_datetime?(%DateTime{}), do: true
  defp valid_datetime?(_datetime), do: false

  defp valid_digest?(digest) when is_binary(digest),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp valid_digest?(_digest), do: false

  defp valid_failure_reason?(reason) do
    reason == String.trim(reason) and reason != "" and byte_size(reason) <= 255
  end

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
