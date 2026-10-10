defmodule Manifold.Data.SyncState do
  @moduledoc "Transaction-local staging for durable iCloud resource intents. No network IO."

  import Ecto.Query

  alias Manifold.Data.Schema.{
    Calendar,
    CalendarEvent,
    Contact,
    DAVCollection,
    DAVResource,
    ICloudConnection
  }

  alias Manifold.Repo

  @doc "Locks all observed and requested Accounts in stable order before other rows."
  def lock_accounts(account_ids) do
    account_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn account_id, {:ok, accounts} ->
      account =
        Repo.one(
          from a in "mailboxes",
            where: a.id == type(^account_id, :binary_id),
            lock: "FOR UPDATE",
            select: %{active: a.active, purge_requested_at: a.purge_requested_at}
        )

      cond do
        is_nil(account) -> {:halt, {:error, :account_not_found}}
        account.purge_requested_at -> {:halt, {:error, :account_purging}}
        true -> {:cont, {:ok, Map.put(accounts, account_id, account)}}
      end
    end)
  end

  @doc "Locks Account, connection, then resource. Call before locking local records."
  def lock_target(kind, account_id, resource_id \\ nil) do
    with {:ok, accounts} <- lock_accounts([account_id]) do
      account = Map.get(accounts, account_id)
      binding = if resource_id, do: Repo.get(DAVResource, resource_id)

      connection =
        cond do
          binding && binding.connection_id ->
            Repo.one(
              from c in ICloudConnection,
                where: c.id == ^binding.connection_id,
                lock: "FOR UPDATE"
            )

          account_id ->
            Repo.one(
              from c in ICloudConnection, where: c.account_id == ^account_id, lock: "FOR UPDATE"
            )

          true ->
            nil
        end

      resource =
        if binding,
          do: Repo.one(from r in DAVResource, where: r.id == ^binding.id, lock: "FOR UPDATE")

      {:ok,
       %{
         account: account,
         connection: connection,
         resource: resource,
         active: not is_nil(account) and account.active,
         kind: kind
       }}
    end
  end

  @doc "Stages the persisted contact inside the caller's transaction."
  def stage_contact(%Contact{} = contact, operation \\ "upsert") do
    collection =
      cond do
        contact.collection_id ->
          Repo.get(DAVCollection, contact.collection_id)

        contact.account_id ->
          connection = Repo.get_by(ICloudConnection, account_id: contact.account_id)

          if connection && connection.default_contacts_collection_id,
            do: Repo.get(DAVCollection, connection.default_contacts_collection_id)

        true ->
          nil
      end

    stage(contact, "contacts", contact.account_id, collection, contact.sync_to_icloud, operation)
  end

  @doc "Stages one full calendar resource; sibling components share its revision."
  def stage_event(%CalendarEvent{} = event, %Calendar{} = calendar, operation \\ "upsert") do
    collection = if calendar.collection_id, do: Repo.get(DAVCollection, calendar.collection_id)
    stage(event, "calendars", calendar.account_id, collection, calendar.sync_to_icloud, operation)
  end

  @doc "Enrolls only explicitly Account-owned drafts after destination configuration."
  def enroll_account(account_id) do
    Repo.transaction(fn ->
      case lock_target("contacts", account_id) do
        {:error, reason} ->
          Repo.rollback(reason)

        {:ok, _} ->
          contacts =
            Repo.all(
              from c in Contact,
                where:
                  c.account_id == ^account_id and c.sync_to_icloud and is_nil(c.deleted_at) and
                    is_nil(c.resource_id),
                order_by: c.id,
                lock: "FOR UPDATE"
            )

          Enum.each(contacts, &stage_contact/1)

          calendars =
            Repo.all(
              from c in Calendar,
                where:
                  c.account_id == ^account_id and c.sync_to_icloud and not is_nil(c.collection_id),
                order_by: c.id
            )

          Enum.each(calendars, fn calendar ->
            events =
              Repo.all(
                from e in CalendarEvent,
                  where:
                    e.calendar_id == ^calendar.id and is_nil(e.deleted_at) and
                      is_nil(e.resource_id),
                  order_by: e.id,
                  lock: "FOR UPDATE"
              )

            Enum.each(events, &stage_event(&1, calendar))
          end)

          %{contacts: length(contacts), calendars: length(calendars)}
      end
    end)
  end

  @doc "Returns pending resources whose retry deadline permits a worker attempt."
  def pending_resources(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 100) |> max(1) |> min(500)

    Repo.all(
      from r in DAVResource,
        where:
          r.status in ["pending", "uncertain", "failed"] and
            (is_nil(r.retry_at) or r.retry_at <= ^now),
        order_by: [asc: r.updated_at, asc: r.id],
        limit: ^limit
    )
  end

  defp stage(record, kind, account_id, collection, preference, operation) do
    existing = if record.resource_id, do: Repo.get!(DAVResource, record.resource_id)

    cond do
      existing ->
        update_intent(record, existing, kind, preference, operation)

      is_nil(collection) ->
        record

      record.collection_id ->
        bind_import(record, collection, kind, account_id, preference, operation)

      not preference ->
        record

      collection.can_create == false or
          (not collection.writable and collection.can_create != true) ->
        record

      true ->
        connection = Repo.get!(ICloudConnection, collection.connection_id)
        # Do not upload into another Account's destination.
        if connection.account_id != account_id or is_nil(account_id) do
          if record.collection_id do
            bind_import(record, collection, kind, account_id, preference, operation)
          else
            record
          end
        else
          bind_import(record, collection, kind, account_id, preference, operation)
        end
    end
  end

  defp bind_import(record, collection, kind, account_id, preference, operation) do
    uid = record.uid || Ecto.UUID.generate()
    extension = if kind == "contacts", do: ".vcf", else: ".ics"

    href =
      record.resource_href ||
        String.trim_trailing(collection.href, "/") <> "/" <> uid <> extension

    resource =
      Repo.get_by(DAVResource, collection_id: collection.id, href: href) ||
        %DAVResource{}
        |> DAVResource.changeset(%{
          kind: kind,
          account_id: account_id,
          connection_id: collection.connection_id,
          collection_id: collection.id,
          href: href,
          uid: uid,
          base_raw: record.raw,
          etag: record.etag,
          remote_raw: record.raw,
          remote_etag: record.etag,
          status: "synced"
        })
        |> Repo.insert!()

    record =
      record
      |> Ecto.Changeset.change(
        resource_id: resource.id,
        uid: uid,
        resource_href: href,
        collection_id: collection.id
      )
      |> Repo.update!()

    if kind == "calendars" do
      Repo.update_all(
        from(e in CalendarEvent,
          where:
            e.collection_id == ^collection.id and e.resource_href == ^href and
              is_nil(e.resource_id)
        ),
        set: [resource_id: resource.id]
      )
    end

    update_intent(record, resource, kind, preference, operation)
  end

  defp update_intent(record, resource, kind, preference, operation) do
    revision = resource.desired_revision + 1
    connection = if resource.connection_id, do: Repo.get(ICloudConnection, resource.connection_id)

    account_active =
      resource.account_id &&
        Repo.one(
          from a in "mailboxes",
            where: a.id == type(^resource.account_id, :binary_id),
            select: a.active and is_nil(a.purge_requested_at)
        )

    service_enabled =
      connection &&
        if(kind == "contacts",
          do: connection.contacts_enabled,
          else: connection.calendars_enabled
        )

    enabled =
      preference and account_active == true and not is_nil(connection) and connection.enabled and
        service_enabled == true

    cancel_create =
      operation == "delete" and is_nil(resource.base_raw) and is_nil(resource.sent_revision)

    status =
      cond do
        resource.status in ["uncertain", "conflict"] -> resource.status
        cancel_create -> "synced"
        enabled -> "pending"
        true -> "paused"
      end

    attrs = %{desired_revision: revision, operation: operation, status: status}
    attrs = if cancel_create, do: Map.put(attrs, :acknowledged_revision, revision), else: attrs
    resource = resource |> DAVResource.changeset(attrs) |> Repo.update!()
    if resource.status == "pending" and enabled, do: wake(connection)
    record
  end

  defp wake(connection) do
    args = %{"connection_id" => connection.id, "generation" => connection.generation}
    worker = "Manifold.Connectors.Jobs.SyncICloud"
    # The connection row lock serializes coalescing without an Oban process.
    queued =
      Repo.exists?(
        from j in Oban.Job,
          where:
            j.worker == ^worker and
              j.state in ["available", "scheduled", "executing", "retryable"] and
              fragment("? @> ?", j.args, type(^args, :map))
      )

    unless queued do
      args |> Oban.Job.new(worker: worker, queue: :connectors, max_attempts: 10) |> Repo.insert!()
    end
  end
end
