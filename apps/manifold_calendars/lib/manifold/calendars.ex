defmodule Manifold.Calendars do
  @moduledoc "Local calendars and events with durable full-resource iCloud intents."

  import Ecto.Query

  alias Manifold.Data.Schema.{
    Calendar,
    CalendarEvent,
    DAVCollection,
    DAVResource,
    ICloudConnection
  }

  alias Manifold.Data.SyncState
  alias Manifold.Repo

  def list_calendars(opts \\ []) do
    query = from c in Calendar, order_by: [asc: fragment("lower(?)", c.name), asc: c.id]

    query =
      if account_id = Keyword.get(opts, :account_id),
        do: where(query, [c], c.account_id == ^account_id),
        else: query

    query |> Repo.all() |> preload_sources()
  end

  def get_calendar(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Calendar{} = calendar <- Repo.get(Calendar, uuid),
         do: preload_sources(calendar),
         else: (_ -> nil)
  end

  def change_calendar(calendar, attrs \\ %{}), do: Calendar.changeset(calendar, attrs)

  def create_calendar(attrs) do
    changeset = Calendar.changeset(%Calendar{}, attrs)

    transaction_if_valid(changeset, fn ->
      account_id = Ecto.Changeset.get_field(changeset, :account_id)
      lock_target!(account_id)
      collection_id = Ecto.Changeset.get_field(changeset, :collection_id)
      ensure_destination!(account_id, collection_id)
      {_, destination, events} = lock_mapping!(nil, account_id, collection_id, attrs)
      if destination, do: Repo.delete!(destination)
      created = persist!(changeset, :insert)
      adopt_events!(destination, created, events)
      created
    end)
  end

  def update_calendar(id, attrs) do
    case get_calendar(id) do
      nil ->
        {:error, :not_found}

      calendar ->
        changeset = Calendar.changeset(calendar, attrs)

        transaction_if_valid(changeset, fn ->
          account_id = Ecto.Changeset.get_field(changeset, :account_id)
          collection_id = Ecto.Changeset.get_field(changeset, :collection_id)
          lock_accounts!([calendar.account_id, account_id])
          ensure_mapping_change!(calendar, account_id, collection_id)
          lock_target!(calendar.account_id)
          lock_target!(account_id)
          ensure_destination!(account_id, collection_id)

          {current, destination, events} =
            lock_mapping!(calendar, account_id, collection_id, attrs)

          ensure_mapping_change!(current, account_id, collection_id)

          if destination do
            move_events!(destination.id, current.id)
            Repo.delete!(destination)
          end

          updated = current |> Calendar.changeset(attrs) |> persist!(:update)
          update_adopted_preference!(destination, updated, events)

          if updated.sync_to_icloud != current.sync_to_icloud or
               collection_id != current.collection_id or account_id != current.account_id do
            Enum.each(events, fn event ->
              if event.calendar_id == current.id and is_nil(event.deleted_at) and
                   (is_nil(event.resource_id) or updated.sync_to_icloud != current.sync_to_icloud),
                 do: SyncState.stage_event(event, updated)
            end)
          end

          updated
        end)
    end
  end

  def delete_calendar(id) do
    case get_calendar(id) do
      nil ->
        {:error, :not_found}

      calendar ->
        Repo.transaction(fn ->
          lock_target!(calendar.account_id)
          current = Repo.one(from c in Calendar, where: c.id == ^calendar.id, lock: "FOR UPDATE")
          if is_nil(current), do: Repo.rollback(:not_found)
          ensure_identity!(current, calendar, [:account_id, :collection_id])

          if Repo.exists?(
               from e in CalendarEvent,
                 join: r in DAVResource,
                 on: r.id == e.resource_id,
                 where:
                   e.calendar_id == ^current.id and
                     (r.desired_revision > r.acknowledged_revision or
                        not is_nil(r.sent_revision) or r.status == "conflict")
             ),
             do: Repo.rollback(:sync_pending)

          if Repo.exists?(
               CalendarEvent
               |> where([e], e.calendar_id == ^calendar.id)
               |> visible_events(true)
             ),
             do: Repo.rollback(:not_empty)

          Repo.delete!(current)
        end)
    end
  end

  def list_events(calendar_id, opts \\ []) do
    with {:ok, uuid} <- Ecto.UUID.cast(calendar_id) do
      limit = bounded_integer(Keyword.get(opts, :limit), 100, 1, 500)
      offset = bounded_integer(Keyword.get(opts, :offset), 0, 0, 1_000_000)

      CalendarEvent
      |> where([e], e.calendar_id == ^uuid or e.collection_id == ^uuid)
      |> visible_events(Keyword.get(opts, :include_deleted_conflicts, false))
      |> order_by([e], asc: e.starts_at, asc: e.uid, asc: e.recurrence_id, asc: e.id)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()
      |> preload_sources()
    else
      _ -> []
    end
  end

  def get_event(id, opts \\ []) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %CalendarEvent{} = event <- Repo.get(CalendarEvent, uuid) do
      event = preload_sources(event)

      if is_nil(event.deleted_at) or
           (Keyword.get(opts, :include_deleted_conflicts, false) and
              match?(%{status: "conflict"}, event.resource)),
         do: event
    else
      _ -> nil
    end
  end

  def change_event(event, attrs \\ %{}), do: CalendarEvent.local_changeset(event, attrs)

  def create_event(attrs) do
    changeset = CalendarEvent.local_changeset(%CalendarEvent{}, attrs)

    transaction_if_valid(changeset, fn ->
      calendar = Repo.get(Calendar, Ecto.Changeset.get_field(changeset, :calendar_id))
      if is_nil(calendar), do: Repo.rollback(:calendar_not_found)
      lock_target!(calendar.account_id)
      calendar = lock_calendar!(calendar)
      ensure_editable!(calendar, :create)

      event =
        changeset
        |> Ecto.Changeset.change(uid: Ecto.UUID.generate(), local_revision: 1)
        |> persist!(:insert)

      SyncState.stage_event(event, calendar)
    end)
  end

  def update_event(id, attrs) do
    case get_event(id) do
      nil ->
        {:error, :not_found}

      event ->
        changeset = CalendarEvent.local_changeset(event, attrs)

        transaction_if_valid(changeset, fn ->
          if Ecto.Changeset.get_field(changeset, :calendar_id) != event.calendar_id,
            do: Repo.rollback(:local_copy_required)

          calendar = Repo.get(Calendar, event.calendar_id)
          if is_nil(calendar), do: Repo.rollback(:calendar_not_found)
          lock_target!(calendar.account_id, event.resource_id)
          calendar = lock_calendar!(calendar)

          current =
            Repo.one(from e in CalendarEvent, where: e.id == ^event.id, lock: "FOR UPDATE")

          if is_nil(current) or current.deleted_at, do: Repo.rollback(:not_found)
          ensure_identity!(current, event, [:calendar_id, :collection_id, :resource_id])
          ensure_editable!(calendar, :update)

          updated =
            current
            |> CalendarEvent.local_changeset(attrs)
            |> Ecto.Changeset.put_change(:local_revision, current.local_revision + 1)
            |> persist!(:update)

          SyncState.stage_event(updated, calendar)
        end)
    end
  end

  @doc "Deletes a stored component; whole_series: true deletes matching UID components."
  def delete_event(id, opts \\ []) do
    case get_event(id) do
      nil ->
        {:error, :not_found}

      event ->
        Repo.transaction(fn ->
          calendar = Repo.get(Calendar, event.calendar_id)
          if is_nil(calendar), do: Repo.rollback(:calendar_not_found)
          lock_target!(calendar.account_id, event.resource_id)
          calendar = lock_calendar!(calendar)

          current =
            Repo.one(from e in CalendarEvent, where: e.id == ^event.id, lock: "FOR UPDATE")

          if is_nil(current) or current.deleted_at, do: Repo.rollback(:not_found)
          ensure_identity!(current, event, [:calendar_id, :collection_id, :resource_id])

          if is_nil(current.resource_id) and is_nil(current.collection_id) do
            Repo.delete!(current)
          else
            targets =
              if Keyword.get(opts, :whole_series, false),
                do:
                  Repo.all(
                    from e in resource_events_query(current),
                      where:
                        e.uid == ^current.uid and
                          is_nil(e.deleted_at),
                      order_by: e.id,
                      lock: "FOR UPDATE"
                  ),
                else: [current]

            Enum.each(targets, fn target ->
              target
              |> Ecto.Changeset.change(
                deleted_at: DateTime.utc_now(),
                local_revision: target.local_revision + 1
              )
              |> persist!(:update)
            end)

            sibling_query = from e in resource_events_query(current), where: is_nil(e.deleted_at)

            operation = if Repo.exists?(sibling_query), do: "upsert", else: "delete"
            ensure_editable!(calendar, if(operation == "upsert", do: :update, else: :delete))
            SyncState.stage_event(Repo.get!(CalendarEvent, current.id), calendar, operation)
          end
        end)
    end
  end

  def copy_event(id, attrs \\ %{}) do
    case get_event(id) do
      nil ->
        {:error, :not_found}

      event ->
        fields = [:summary, :description, :location, :starts_at, :ends_at, :timezone, :all_day]

        overrides =
          Map.new(
            for key <- fields ++ [:calendar_id],
                Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)),
                do: {key, Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))}
          )

        create_event(Map.merge(Map.take(event, fields), overrides))
    end
  end

  defp lock_target!(account_id, resource_id \\ nil) do
    case SyncState.lock_target("calendars", account_id, resource_id) do
      {:ok, target} -> target
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resource_events_query(%CalendarEvent{resource_id: resource_id})
       when not is_nil(resource_id),
       do: from(e in CalendarEvent, where: e.resource_id == ^resource_id)

  defp resource_events_query(event),
    do:
      from(e in CalendarEvent,
        where: e.collection_id == ^event.collection_id and e.resource_href == ^event.resource_href
      )

  defp lock_resources!(account_id, events) do
    events
    |> Enum.map(& &1.resource_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&lock_target!(account_id, &1))
  end

  defp lock_accounts!(account_ids) do
    case SyncState.lock_accounts(account_ids) do
      {:ok, accounts} -> accounts
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_mapping!(source, account_id, collection_id, attrs) do
    destination =
      if collection_id, do: Repo.get_by(Calendar, collection_id: collection_id)

    destination =
      if destination && source && destination.id == source.id, do: nil, else: destination

    if destination do
      if Map.get(attrs, :merge_destination, Map.get(attrs, "merge_destination")) not in [
           true,
           "true"
         ],
         do: Repo.rollback(:merge_required)

      if is_nil(account_id) or destination.account_id != account_id,
        do: Repo.rollback(:invalid_destination)
    end

    observed = Enum.reject([source, destination], &is_nil/1)
    ids = Enum.map(observed, & &1.id)
    events = Repo.all(from e in CalendarEvent, where: e.calendar_id in ^ids, order_by: e.id)
    lock_resources!(account_id, events)
    locked = Repo.all(from c in Calendar, where: c.id in ^ids, order_by: c.id, lock: "FOR UPDATE")

    Enum.each(observed, fn calendar ->
      current = Enum.find(locked, &(&1.id == calendar.id))
      if is_nil(current), do: Repo.rollback(:stale)
      ensure_identity!(current, calendar, [:account_id, :collection_id])
    end)

    events =
      Repo.all(
        from e in CalendarEvent, where: e.calendar_id in ^ids, order_by: e.id, lock: "FOR UPDATE"
      )

    {if(source, do: Enum.find(locked, &(&1.id == source.id))),
     if(destination, do: Enum.find(locked, &(&1.id == destination.id))), events}
  end

  defp adopt_events!(nil, _created, _events), do: :ok

  defp adopt_events!(destination, created, events) do
    ids = Enum.map(events, & &1.id)
    Repo.update_all(from(e in CalendarEvent, where: e.id in ^ids), set: [calendar_id: created.id])
    update_adopted_preference!(destination, created, events)
  end

  defp move_events!(previous_id, current_id) do
    Repo.update_all(from(e in CalendarEvent, where: e.calendar_id == ^previous_id),
      set: [calendar_id: current_id]
    )
  end

  defp update_adopted_preference!(nil, _updated, _events), do: :ok

  defp update_adopted_preference!(previous, updated, events) do
    if previous.sync_to_icloud != updated.sync_to_icloud do
      account = lock_target!(updated.account_id)

      enabled =
        updated.sync_to_icloud and account.active and not is_nil(account.connection) and
          account.connection.enabled and account.connection.calendars_enabled

      events
      |> Enum.filter(&(&1.calendar_id == previous.id))
      |> Enum.map(& &1.resource_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.each(fn id ->
        resource = Repo.get!(DAVResource, id)

        status =
          cond do
            resource.status in ["uncertain", "conflict"] or resource.sent_revision ->
              resource.status

            not enabled ->
              "paused"

            resource.desired_revision > resource.acknowledged_revision ->
              "pending"

            true ->
              "synced"
          end

        resource |> Ecto.Changeset.change(status: status) |> Repo.update!()
      end)
    end
  end

  defp lock_calendar!(observed) do
    current = Repo.one(from c in Calendar, where: c.id == ^observed.id, lock: "FOR UPDATE")
    if is_nil(current), do: Repo.rollback(:calendar_not_found)
    ensure_identity!(current, observed, [:account_id, :collection_id])
    current
  end

  defp ensure_identity!(current, observed, fields) do
    if Map.take(current, fields) != Map.take(observed, fields), do: Repo.rollback(:stale)
  end

  defp ensure_mapping_change!(calendar, account_id, collection_id) do
    if (account_id != calendar.account_id or collection_id != calendar.collection_id) and
         Repo.exists?(
           from e in CalendarEvent,
             where: e.calendar_id == ^calendar.id and not is_nil(e.resource_id)
         ),
       do: Repo.rollback(:local_copy_required)
  end

  defp ensure_destination!(_account_id, nil), do: :ok

  defp ensure_destination!(account_id, collection_id) do
    collection = Repo.get(DAVCollection, collection_id)
    connection = if collection, do: Repo.get(ICloudConnection, collection.connection_id)

    if is_nil(collection) or collection.kind != "calendars" or is_nil(connection) or
         is_nil(account_id) or connection.account_id != account_id,
       do: Repo.rollback(:invalid_destination)
  end

  defp ensure_editable!(%Calendar{sync_to_icloud: true, collection_id: collection_id}, operation)
       when not is_nil(collection_id) do
    collection = Repo.get(DAVCollection, collection_id)
    capability = %{create: :can_create, update: :can_update, delete: :can_delete}[operation]

    if collection &&
         (Map.get(collection, capability) == false or
            (Map.get(collection, capability) != true and not collection.writable)),
       do: Repo.rollback(:read_only)
  end

  defp ensure_editable!(_, _), do: :ok

  defp transaction_if_valid(%Ecto.Changeset{valid?: false} = changeset, _fun),
    do: {:error, changeset}

  defp transaction_if_valid(_changeset, fun), do: Repo.transaction(fun)

  defp persist!(changeset, operation) do
    case apply(Repo, operation, [changeset]) do
      {:ok, record} -> record
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp preload_sources(%Calendar{} = calendar),
    do: Repo.preload(calendar, collection: [connection: public_connections()])

  defp preload_sources([%Calendar{} | _] = calendars),
    do: Repo.preload(calendars, collection: [connection: public_connections()])

  defp preload_sources(events),
    do:
      Repo.preload(events, [:calendar, :resource, collection: [connection: public_connections()]])

  defp public_connections do
    from c in ICloudConnection,
      select:
        struct(c, [
          :id,
          :account_id,
          :apple_id,
          :enabled,
          :contacts_enabled,
          :calendars_enabled,
          :contacts_status,
          :contacts_synced_at,
          :calendars_status,
          :calendars_synced_at
        ])
  end

  defp visible_events(query, false), do: where(query, [e], is_nil(e.deleted_at))

  defp visible_events(query, true),
    do:
      from(e in query,
        left_join: r in DAVResource,
        on: e.resource_id == r.id,
        where: is_nil(e.deleted_at) or r.status == "conflict"
      )

  defp bounded_integer(value, _default, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp bounded_integer(_, default, _, _), do: default
end
