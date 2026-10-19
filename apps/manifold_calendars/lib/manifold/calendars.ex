defmodule Manifold.Calendars do
  @moduledoc "Provider-independent local calendars, series and durable target intents."
  import Ecto.Query
  alias Manifold.Data.Schema.{Calendar, CalendarEvent, CalendarBinding, CalendarEventBinding}
  alias Manifold.Data.CalendarSyncState
  alias Manifold.Calendars.{Recurrence, Time}
  alias Manifold.Repo

  @fields ~w(summary description location starts_at ends_at timezone all_day recurrence_rules recurrence_dates excluded_dates recurrence_timezone reminders)a

  def list_calendars(_opts \\ []) do
    Repo.all(
      from c in Calendar,
        where: is_nil(c.deleted_at),
        order_by: [asc: fragment("lower(?)", c.name), asc: c.id]
    )
    |> Repo.preload(:bindings)
  end

  def get_calendar(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Calendar{deleted_at: nil} = calendar <- Repo.get(Calendar, uuid),
         do: Repo.preload(calendar, :bindings),
         else: (_ -> nil)
  end

  def change_calendar(calendar, attrs \\ %{}), do: Calendar.changeset(calendar, attrs)

  def create_calendar(attrs) do
    if legacy_settings?(attrs),
      do: {:error, :use_sync_bindings},
      else: transaction(fn -> persist!(Calendar.changeset(%Calendar{}, attrs), :insert) end)
  end

  def update_calendar(id, attrs) do
    if legacy_settings?(attrs),
      do: {:error, :use_sync_bindings},
      else:
        transaction(fn ->
          lock_calendar!(id) |> Calendar.changeset(attrs) |> persist!(:update)
        end)
  end

  @doc "Archives local data and synchronization identities without deleting remote data."
  def delete_calendar(id, _opts \\ []) do
    transaction(fn ->
      calendar = lock_calendar!(id)
      now = DateTime.utc_now()

      bindings =
        Repo.all(
          from b in CalendarBinding,
            where: b.calendar_id == ^calendar.id,
            order_by: b.id,
            lock: "FOR UPDATE"
        )

      Enum.each(bindings, fn binding ->
        binding
        |> Ecto.Changeset.change(
          state: "detached",
          generation: binding.generation + 1,
          suppressed_at: now
        )
        |> Repo.update!()
      end)

      calendar |> Ecto.Changeset.change(deleted_at: now) |> Repo.update!()
    end)
  end

  def list_events(calendar_id, opts \\ []) do
    with {:ok, uuid} <- Ecto.UUID.cast(calendar_id), %Calendar{} <- get_calendar(uuid) do
      query =
        from e in CalendarEvent,
          where: e.calendar_id == ^uuid,
          order_by: [asc: e.starts_at, asc: e.uid, asc: e.recurrence_id, asc: e.id]

      query =
        if Keyword.get(opts, :include_deleted, false),
          do: query,
          else: where(query, [e], is_nil(e.deleted_at))

      query
      |> limit(^bounded(Keyword.get(opts, :limit), 500, 1, 10_000))
      |> offset(^bounded(Keyword.get(opts, :offset), 0, 0, 1_000_000))
      |> Repo.all()
      |> preload_event()
    else
      _ -> []
    end
  end

  def get_event(id, opts \\ []) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %CalendarEvent{} = event <- Repo.get(CalendarEvent, uuid),
         %Calendar{} <- get_calendar(event.calendar_id),
         true <- is_nil(event.deleted_at) or Keyword.get(opts, :include_deleted, false),
         do: preload_event(event),
         else: (_ -> nil)
  end

  @doc "Expands all selected calendars in a bounded viewing range; errors are explicit."
  def list_occurrences(calendar_ids, opts) do
    first = Keyword.fetch!(opts, :from)
    until = Keyword.fetch!(opts, :until)
    zone = Keyword.get(opts, :timezone, "Etc/UTC")
    ids = List.wrap(calendar_ids) |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))

    events =
      Repo.all(
        from e in CalendarEvent,
          join: c in Calendar,
          on: c.id == e.calendar_id,
          where: e.calendar_id in ^ids and is_nil(c.deleted_at),
          order_by: e.id,
          limit: 10_001
      )

    if length(events) > 10_000,
      do: {:error, [%{event_id: nil, reason: :event_limit}]},
      else: Recurrence.occurrences(preload_event(events), first, until, zone)
  end

  # Compatibility for record consumers. New views consume list_occurrences/2.
  def list_events_in_range(id, first, until, opts \\ []) do
    case list_occurrences([id],
           from: first,
           until: until,
           timezone: Keyword.get(opts, :timezone, "Etc/UTC")
         ) do
      {:ok, occurrences} -> occurrences |> Enum.map(& &1.event) |> Enum.uniq_by(& &1.id)
      {:error, _} = error -> error
    end
  end

  def change_event(event, attrs \\ %{}), do: CalendarEvent.local_changeset(event, attrs)

  def create_event(calendar_id, attrs),
    do: create_event(Map.put(attrs, :calendar_id, calendar_id))

  def create_event(attrs) do
    transaction(fn ->
      calendar = lock_calendar!(value(attrs, :calendar_id))
      event = new_event!(calendar, attrs, Ecto.UUID.generate(), Ecto.UUID.generate())
      CalendarSyncState.stage_events!(calendar, [event])
      event
    end)
  end

  def update_event(id, attrs, opts \\ []) do
    with_event(id, fn calendar, event ->
      expect_revision!(event, opts)
      editable!(event)

      if value(attrs, :calendar_id, event.calendar_id) != event.calendar_id,
        do: Repo.rollback(:copy_required)

      updated = revise!(event, attrs)
      CalendarSyncState.stage_events!(calendar, [updated])
      updated
    end)
  end

  @doc "Edits an occurrence while retaining its original recurrence identity."
  def update_occurrence(id, recurrence_id, attrs, opts \\ []) do
    with_event(id, fn calendar, event ->
      editable!(event)
      master = master!(event)
      validate_slot!(master, recurrence_id)

      current =
        Repo.one(
          from e in CalendarEvent,
            where:
              e.calendar_id == ^calendar.id and e.series_id == ^master.series_id and
                e.recurrence_id == ^recurrence_id,
            lock: "FOR UPDATE"
        )

      expect_revision!(current || master, opts)
      if current, do: editable!(current)

      updated =
        if current do
          revise!(current, attrs)
        else
          occurrence_attrs =
            occurrence_attrs!(master, recurrence_id) |> Map.merge(atom_attrs(attrs))

          new_event!(calendar, occurrence_attrs, master.uid, master.series_id,
            recurrence_id: recurrence_id,
            recurrence_timezone: master.timezone
          )
        end

      CalendarSyncState.stage_events!(calendar, [updated])
      updated
    end)
  end

  @doc "Deletes a single occurrence or an entire series with canonical tombstones."
  def delete_event(id, opts \\ []) do
    with_event(id, fn calendar, event ->
      editable!(event)
      expect_revision!(event, opts)

      scope =
        Keyword.get(opts, :scope, if(Keyword.get(opts, :whole_series), do: :series, else: :event))

      cond do
        scope == :series ->
          events =
            Repo.all(
              from e in CalendarEvent,
                where:
                  e.calendar_id == ^calendar.id and e.series_id == ^event.series_id and
                    is_nil(e.deleted_at),
                order_by: e.id,
                lock: "FOR UPDATE"
            )

          changed = Enum.map(events, &tombstone!/1)
          CalendarSyncState.stage_events!(calendar, changed)
          hd(changed)

        scope == :occurrence or event.recurrence_id not in [nil, ""] ->
          master = master!(event)
          rid = Keyword.get(opts, :recurrence_id, event.recurrence_id)
          validate_slot!(master, rid)
          excluded = Enum.uniq((master.excluded_dates || []) ++ [exclusion(master, rid)])
          updated_master = revise!(master, %{excluded_dates: excluded})

          exception =
            Repo.one(
              from e in CalendarEvent,
                where:
                  e.calendar_id == ^calendar.id and e.series_id == ^master.series_id and
                    e.recurrence_id == ^rid,
                lock: "FOR UPDATE"
            )

          changed =
            [updated_master] ++
              if(exception && is_nil(exception.deleted_at), do: [tombstone!(exception)], else: [])

          CalendarSyncState.stage_events!(calendar, changed)
          List.last(changed)

        event.recurrence_rules != [] or event.recurrence_dates != [] ->
          Repo.rollback(:scope_required)

        true ->
          deleted = tombstone!(event)
          CalendarSyncState.stage_events!(calendar, [deleted])
          deleted
      end
    end)
  end

  def copy_event(id, attrs \\ %{}, opts \\ []) do
    case get_event(id) do
      nil ->
        {:error, :not_found}

      source ->
        destination = value(attrs, :calendar_id, source.calendar_id)
        # Lock both calendars in stable order before their components/targets.
        transaction(fn ->
          calendars =
            [source.calendar_id, destination]
            |> Enum.uniq()
            |> Enum.sort()
            |> Enum.map(&lock_calendar!/1)

          target = Enum.find(calendars, &(&1.id == destination))
          current = Repo.get!(CalendarEvent, source.id)
          if current.deleted_at, do: Repo.rollback(:not_found)
          scope = Keyword.get(opts, :scope, :event)

          series? =
            current.recurrence_rules != [] or current.recurrence_dates != [] or
              current.recurrence_id not in [nil, ""]

          if scope == :event and series?, do: Repo.rollback(:scope_required)

          components =
            if scope == :series,
              do:
                Repo.all(
                  from e in CalendarEvent,
                    where:
                      e.calendar_id == ^current.calendar_id and e.series_id == ^current.series_id,
                    order_by: e.recurrence_id
                ),
              else: [current]

          components =
            if scope == :occurrence do
              master = master!(current)
              rid = Keyword.get(opts, :recurrence_id, current.recurrence_id)
              validate_slot!(master, rid)

              exception =
                Repo.one(
                  from e in CalendarEvent,
                    where:
                      e.calendar_id == ^master.calendar_id and e.series_id == ^master.series_id and
                        e.recurrence_id == ^rid
                )

              if exception && exception.deleted_at, do: Repo.rollback(:not_found)
              [exception || Map.merge(master, occurrence_attrs!(master, rid))]
            else
              components
            end

          uid = Ecto.UUID.generate()
          series = Ecto.UUID.generate()

          copies =
            Enum.map(components, fn component ->
              properties =
                Map.take(component, @fields)
                |> Map.merge(atom_attrs(attrs))
                |> Map.put(:calendar_id, target.id)

              properties =
                if scope == :occurrence,
                  do:
                    Map.merge(properties, %{
                      recurrence_rules: [],
                      recurrence_dates: [],
                      excluded_dates: []
                    }),
                  else: properties

              copy =
                new_event!(target, properties, uid, series,
                  recurrence_id: if(scope == :series, do: component.recurrence_id, else: "")
                )

              if scope == :series and component.deleted_at, do: tombstone!(copy), else: copy
            end)

          CalendarSyncState.stage_events!(target, copies)
          Enum.find(copies, hd(copies), &(&1.recurrence_id in [nil, ""]))
        end)
    end
  end

  def list_bindings(calendar_id) do
    connections =
      from c in Manifold.Data.Schema.CalendarConnection,
        select:
          struct(c, [:id, :provider, :display_name, :status, :generation, :identity_verified_at])

    Repo.all(from b in CalendarBinding, where: b.calendar_id == ^calendar_id, order_by: b.id)
    |> Repo.preload(connection: connections)
  end

  def sync_summary(calendar_id) do
    Enum.map(list_bindings(calendar_id), fn binding ->
      mappings = Repo.all(from e in CalendarEventBinding, where: e.binding_id == ^binding.id)

      %{
        binding: binding,
        pending: Enum.count(mappings, &(&1.desired_revision > &1.acknowledged_revision)),
        conflicts: Enum.count(mappings, &(not is_nil(&1.conflict))),
        limited: Enum.count(mappings, &(&1.state == "limited"))
      }
    end)
  end

  defp with_event(id, fun) do
    case get_event(id) do
      nil ->
        {:error, :not_found}

      observed ->
        transaction(fn ->
          calendar = lock_calendar!(observed.calendar_id)

          current =
            Repo.one(from e in CalendarEvent, where: e.id == ^observed.id, lock: "FOR UPDATE")

          if is_nil(current) or current.deleted_at, do: Repo.rollback(:not_found)
          fun.(calendar, current)
        end)
    end
  end

  defp new_event!(calendar, attrs, uid, series, extra \\ []) do
    %CalendarEvent{}
    |> CalendarEvent.local_changeset(Map.put(atom_attrs(attrs), :calendar_id, calendar.id))
    |> Ecto.Changeset.change(
      Keyword.merge([uid: uid, series_id: series, local_revision: 1], extra)
    )
    |> persist!(:insert)
  end

  defp revise!(event, attrs),
    do:
      event
      |> CalendarEvent.local_changeset(attrs)
      |> Ecto.Changeset.put_change(:local_revision, event.local_revision + 1)
      |> persist!(:update)

  defp tombstone!(event),
    do:
      event
      |> Ecto.Changeset.change(
        deleted_at: DateTime.utc_now(),
        local_revision: event.local_revision + 1
      )
      |> Repo.update!()

  defp editable!(%{read_only: true}), do: Repo.rollback(:read_only)
  defp editable!(_), do: :ok

  defp expect_revision!(event, opts) do
    if Keyword.get(opts, :expected_revision, event.local_revision) != event.local_revision,
      do: Repo.rollback(:stale)
  end

  defp master!(event) do
    master =
      Repo.one(
        from e in CalendarEvent,
          where:
            e.calendar_id == ^event.calendar_id and e.series_id == ^event.series_id and
              e.recurrence_id == "",
          lock: "FOR UPDATE"
      )

    if is_nil(master) or master.deleted_at, do: Repo.rollback(:series_not_found), else: master
  end

  defp validate_slot!(master, rid) do
    with true <- is_binary(rid) and rid != "",
         {:ok, instant} <- Time.parse(rid, master.recurrence_timezone || master.timezone),
         first = if(is_struct(instant, Date), do: instant, else: DateTime.to_date(instant)),
         {:ok, occurrences} <-
           Recurrence.occurrences(
             [master],
             Date.add(first, -1),
             Date.add(first, 2),
             master.timezone || "Etc/UTC"
           ),
         true <- Enum.any?(occurrences, &(&1.recurrence_id == rid)) do
      :ok
    else
      _ -> Repo.rollback(:invalid_occurrence)
    end
  end

  defp occurrence_attrs!(master, rid) do
    with {:ok, original} <- Time.parse(master.starts_at, master.timezone),
         {:ok, slot} <- Time.parse(rid, master.recurrence_timezone || master.timezone) do
      finish =
        case Time.parse(master.ends_at, master.timezone) do
          {:ok, stop} when is_struct(stop, Date) and is_struct(original, Date) ->
            Date.add(slot, Date.diff(stop, original))

          {:ok, stop} when is_struct(stop, DateTime) and is_struct(original, DateTime) ->
            DateTime.add(slot, DateTime.diff(stop, original))

          _ ->
            nil
        end

      Map.take(master, @fields)
      |> Map.merge(%{
        starts_at: rid,
        ends_at: if(finish, do: source_compact(finish, master), else: nil),
        recurrence_rules: [],
        recurrence_dates: [],
        excluded_dates: []
      })
    else
      _ -> Repo.rollback(:invalid_occurrence)
    end
  end

  defp source_compact(%Date{} = value, _), do: Time.compact(value)

  defp source_compact(value, %{time_kind: "utc"}),
    do: Time.compact(DateTime.shift_zone!(value, "Etc/UTC"))

  defp source_compact(value, _), do: Elixir.Calendar.strftime(value, "%Y%m%dT%H%M%S")

  defp exclusion(master, rid) do
    zone = master.recurrence_timezone || master.timezone

    cond do
      master.all_day -> "EXDATE;VALUE=DATE:" <> rid
      String.ends_with?(rid, "Z") or zone in [nil, "", "Etc/UTC", "UTC"] -> rid
      true -> "EXDATE;TZID=#{zone}:#{rid}"
    end
  end

  defp lock_calendar!(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Calendar{deleted_at: nil} = calendar <-
           Repo.one(from c in Calendar, where: c.id == ^uuid, lock: "FOR UPDATE"),
         do: calendar,
         else: (_ -> Repo.rollback(:calendar_not_found))
  end

  defp legacy_settings?(attrs),
    do:
      Enum.any?(
        [:account_id, :collection_id, :sync_to_icloud, :merge_destination],
        &(Map.has_key?(attrs, &1) or Map.has_key?(attrs, Atom.to_string(&1)))
      )

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp atom_attrs(attrs),
    do:
      Map.new(
        for key <- @fields ++ [:calendar_id],
            Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)),
            do: {key, value(attrs, key)}
      )

  defp bounded(value, _, low, high) when is_integer(value), do: value |> max(low) |> min(high)
  defp bounded(_, default, _, _), do: default

  defp persist!(changeset, operation) do
    case apply(Repo, operation, [changeset]) do
      {:ok, record} -> record
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp transaction(fun) do
    result = Repo.transaction(fun)
    if match?({:ok, _}, result), do: CalendarSyncState.notify()
    result
  end

  defp preload_event(events), do: Repo.preload(events, [:calendar, :resource, :collection])
end
