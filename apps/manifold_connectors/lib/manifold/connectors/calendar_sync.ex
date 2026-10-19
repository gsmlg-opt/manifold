defmodule Manifold.Connectors.CalendarSync do
  @moduledoc "Durable, independently acknowledged synchronization of local calendars."
  import Ecto.Query
  alias Manifold.Data.CalendarSyncState, as: State

  alias Manifold.Data.Schema.{
    Calendar,
    CalendarBinding,
    CalendarConnection,
    CalendarEvent,
    CalendarEventBinding,
    CalendarSyncAttempt,
    CalendarSyncResource
  }

  alias Manifold.Repo
  @unresolved ~w(prepared dispatched uncertain)

  @doc "Read-only comparison for reviewed migration activation; never applies data or sends writes."
  def compare(binding_id, opts \\ []) do
    with %CalendarBinding{} = binding <- Repo.get(CalendarBinding, binding_id),
         connection = Repo.get!(CalendarConnection, binding.connection_id),
         {:ok, %{complete: true} = batch} <-
           adapter(connection, opts).fetch_changes(binding, %{}, opts),
         {:ok, batch} <- decode_batch(adapter(connection, opts), batch, opts) do
      resources =
        Enum.map(batch.resources, fn snapshot ->
          resource =
            Repo.get_by(CalendarSyncResource,
              binding_id: binding.id,
              remote_resource_id: snapshot.id
            )

          components =
            Enum.map(snapshot.components, fn component ->
              eb =
                if resource,
                  do:
                    Repo.get_by(CalendarEventBinding,
                      resource_id: resource.id,
                      remote_component_key: component.key
                    )

              event = if eb, do: Repo.get!(CalendarEvent, eb.event_id)
              fields = Map.get(component, :fields, Map.keys(component.projection))
              current = if event, do: State.projection(event)
              base = if eb, do: eb.base_projection, else: %{}

              status =
                cond do
                  is_nil(eb) -> "unbound"
                  State.equivalent?(current, component.projection, fields) -> "equivalent"
                  State.equivalent?(base, component.projection, fields) -> "local_changed"
                  State.equivalent?(base, current, fields) -> "remote_changed"
                  true -> "conflict"
                end

              %{
                key: component.key,
                event_id: event && event.id,
                local_revision: event && event.local_revision,
                local: current,
                base: base,
                remote: component.projection,
                fields: fields,
                status: status
              }
            end)
            |> Enum.sort_by(& &1.key)

          %{
            id: snapshot.id,
            etag: snapshot[:etag],
            presence: Atom.to_string(snapshot.presence),
            raw_hash:
              if(snapshot[:raw],
                do: Base.encode16(:crypto.hash(:sha256, snapshot.raw), case: :lower)
              ),
            components: components
          }
        end)
        |> Enum.sort_by(& &1.id)

      known = Repo.all(from r in CalendarSyncResource, where: r.binding_id == ^binding.id)
      seen = Enum.map(resources, & &1.id)

      missing =
        for resource <- known, resource.remote_resource_id not in seen do
          ebs = Repo.all(from eb in CalendarEventBinding, where: eb.resource_id == ^resource.id)

          components =
            Enum.map(ebs, fn eb ->
              event = Repo.get!(CalendarEvent, eb.event_id)

              remote =
                if batch.mode == :full,
                  do: Map.put(eb.base_projection, "deleted", true),
                  else: nil

              status =
                cond do
                  batch.mode != :full -> "awaiting_snapshot"
                  event.deleted_at != nil -> "equivalent"
                  event.local_revision > eb.acknowledged_revision -> "conflict"
                  true -> "remote_changed"
                end

              %{
                key: eb.remote_component_key,
                event_id: event.id,
                local_revision: event.local_revision,
                local: State.projection(event),
                base: eb.base_projection,
                remote: remote,
                fields: eb.projection_fields,
                status: status
              }
            end)
            |> Enum.sort_by(& &1.key)

          %{
            id: resource.remote_resource_id,
            etag: nil,
            presence: if(batch.mode == :full, do: "deleted", else: "unknown"),
            raw_hash: nil,
            components: components
          }
        end

      resources =
        Enum.map(resources ++ missing, fn report ->
          resource = Enum.find(known, &(&1.remote_resource_id == report.id))

          attempts =
            if resource do
              Repo.all(
                from a in CalendarSyncAttempt,
                  where: a.resource_id == ^resource.id and a.state in ^@unresolved,
                  order_by: a.id
              )
              |> Enum.map(fn a ->
                %{
                  id: a.id,
                  state: a.state,
                  operation: a.operation,
                  destination: a.destination,
                  request_hash:
                    Base.encode16(:crypto.hash(:sha256, a.payload || ""), case: :lower),
                  component_revisions: a.component_revisions,
                  precondition: a.precondition,
                  connection_generation: a.connection_generation,
                  binding_generation: a.binding_generation
                }
              end)
            else
              []
            end

          Map.put(report, :unresolved_attempts, attempts)
        end)
        |> Enum.sort_by(& &1.id)

      {:ok,
       %{
         complete: true,
         mode: Atom.to_string(batch.mode),
         checkpoint: batch.checkpoint,
         binding_generation: binding.generation,
         connection_generation: connection.generation,
         resources: resources
       }}
    else
      nil -> {:error, :not_found}
      {:ok, _} -> {:error, :incomplete_batch}
      error -> error
    end
  end

  def list_bindings(calendar_id),
    do: Repo.all(from b in CalendarBinding, where: b.calendar_id == ^calendar_id, order_by: b.id)

  @doc "Persist an explicit initial-sync preview. No existing events are uploaded."
  def preview(calendar_id, connection_id, remote_calendar, opts \\ []) do
    with %Calendar{} = calendar <- Repo.get(Calendar, calendar_id),
         %CalendarConnection{} = connection <- Repo.get(CalendarConnection, connection_id),
         true <- connection.status == "active" || {:error, :disabled},
         nil <-
           Repo.get_by(CalendarBinding,
             connection_id: connection_id,
             remote_calendar_id: remote_calendar.id
           ) do
      binding = %CalendarBinding{
        calendar_id: calendar.id,
        connection_id: connection.id,
        remote_calendar_id: remote_calendar.id,
        name: remote_calendar.name,
        capabilities: Map.get(remote_calendar, :capabilities, %{}),
        state: "preview",
        direction: Keyword.get(opts, :direction, "bidirectional")
      }

      adapter = adapter(connection, opts)

      with {:ok, %{complete: true} = batch} <- adapter.fetch_changes(binding, %{}, opts),
           {:ok, decoded} <- decode_batch(adapter, batch, opts) do
        events =
          Repo.all(
            from e in CalendarEvent, where: e.calendar_id == ^calendar.id and is_nil(e.deleted_at)
          )

        token = Ecto.UUID.generate()

        manifest = %{
          "token" => token,
          "local_revisions" => Map.new(events, &{&1.id, &1.local_revision}),
          "resources" => json_value(decoded.resources),
          "checkpoint" => json_value(batch.checkpoint),
          "impact" =>
            "Imported events propagate to other confirmed targets; selected local events upload to this target"
        }

        transaction(fn ->
          lock_calendar!(calendar.id)
          binding |> Ecto.Changeset.change(enrollment_manifest: manifest) |> Repo.insert!()
        end)
      else
        {:ok, _} -> {:error, :incomplete_batch}
        error -> error
      end
    else
      %CalendarBinding{} = existing -> {:error, {:already_bound, existing.id}}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Explicitly preview re-enrollment of an archived target without discarding prior attempts."
  def reenroll_preview(binding_id, opts \\ []) do
    with %CalendarBinding{state: "detached"} = binding <- Repo.get(CalendarBinding, binding_id),
         true <-
           binding.enrollment_manifest["identity_verification_required"] != true and
             binding.enrollment_manifest["baseline_hydration_required"] != true,
         %Calendar{deleted_at: nil} <- Repo.get(Calendar, binding.calendar_id),
         %CalendarConnection{status: "active"} = connection <-
           Repo.get(CalendarConnection, binding.connection_id),
         {:ok, %{complete: true} = batch} <-
           adapter(connection, opts).fetch_changes(binding, %{}, opts),
         {:ok, decoded} <- decode_batch(adapter(connection, opts), batch, opts) do
      events =
        Repo.all(
          from e in CalendarEvent,
            where: e.calendar_id == ^binding.calendar_id and is_nil(e.deleted_at)
        )

      history = binding.enrollment_manifest["prior_enrollments"] || []

      archived = %{
        "generation" => binding.generation,
        "suppressed_at" => binding.suppressed_at && DateTime.to_iso8601(binding.suppressed_at),
        "manifest" => Map.delete(binding.enrollment_manifest, "prior_enrollments")
      }

      manifest = %{
        "token" => Ecto.UUID.generate(),
        "local_revisions" => Map.new(events, &{&1.id, &1.local_revision}),
        "resources" => json_value(decoded.resources),
        "checkpoint" => batch.checkpoint,
        "reenrollment" => true,
        "prior_enrollments" => history ++ [archived],
        "impact" =>
          "Only explicitly selected historical data is re-enrolled. Proven mappings are reused; uncertain prior requests reconcile before any new write. Imports propagate to other confirmed targets."
      }

      transaction(fn ->
        current = lock_context!(binding_id)

        unless current.state == "detached" and current.generation == binding.generation,
          do: Repo.rollback(:stale_preview)

        Repo.update!(
          Ecto.Changeset.change(current,
            state: "preview",
            generation: current.generation + 1,
            enrollment_manifest: manifest
          )
        )
      end)
    else
      false -> {:error, :migration_review_required}
      %CalendarBinding{} -> {:error, :not_detached}
      %Calendar{} -> {:error, :calendar_deleted}
      %CalendarConnection{} -> {:error, :disabled}
      nil -> {:error, :not_found}
      {:ok, _} -> {:error, :incomplete_batch}
      error -> error
    end
  end

  @doc "Confirm exact preview revisions; claims are explicit resource/component to local ID mappings."
  def confirm(binding_id, token, selections, opts \\ []) do
    with :ok <- validate_remote_preview(binding_id, opts) do
      transaction(
        fn ->
          binding = lock_context!(binding_id)
          manifest = binding.enrollment_manifest || %{}

          if binding.state != "preview" or manifest["token"] != token,
            do: Repo.rollback(:stale_preview)

          uploads =
            Map.get(selections, :upload_event_ids, Map.get(selections, "upload_event_ids", []))

          imports =
            Map.get(
              selections,
              :import_resource_ids,
              Map.get(selections, "import_resource_ids", [])
            )

          claims = Map.get(selections, :claims, Map.get(selections, "claims", %{}))

          events =
            Repo.all(
              from e in CalendarEvent,
                where: e.calendar_id == ^binding.calendar_id and is_nil(e.deleted_at),
                order_by: e.id,
                lock: "FOR UPDATE"
            )

          Enum.each(events, fn e ->
            if manifest["local_revisions"][e.id] != e.local_revision,
              do: Repo.rollback(:stale_preview)
          end)

          if Enum.sort(Map.keys(manifest["local_revisions"])) !=
               Enum.sort(Enum.map(events, & &1.id)),
             do: Repo.rollback(:stale_preview)

          unless Enum.all?(uploads, &Map.has_key?(manifest["local_revisions"], &1)),
            do: Repo.rollback(:invalid_selection)

          snapshots = Enum.map(manifest["resources"], &snapshot_from_json/1)

          unless Enum.all?(imports, fn id -> Enum.any?(snapshots, &(&1.id == id)) end),
            do: Repo.rollback(:invalid_selection)

          # Claims never infer equivalence from UID, title or times.
          Enum.each(claims, fn {identity, event_id} ->
            unless event_id in Map.keys(manifest["local_revisions"]),
              do: Repo.rollback(:invalid_claim)

            unless Enum.any?(snapshots, fn s ->
                     Enum.any?(s.components, &(claim_key(s.id, &1.key) == identity))
                   end),
                   do: Repo.rollback(:invalid_claim)
          end)

          unless length(Map.values(claims)) == length(Enum.uniq(Map.values(claims))),
            do: Repo.rollback(:duplicate_claim)

          confirmed =
            manifest
            |> Map.put("confirmed_at", DateTime.utc_now() |> DateTime.to_iso8601())
            |> Map.put("selection", json_value(selections))

          binding =
            Repo.update!(
              Ecto.Changeset.change(binding,
                state: "active",
                suppressed_at: nil,
                enrollment_manifest: confirmed,
                checkpoint: manifest["checkpoint"]
              )
            )

          if manifest["reenrollment"] do
            Repo.update_all(from(eb in CalendarEventBinding, where: eb.binding_id == ^binding.id),
              set: [state: "suppressed"]
            )

            for snapshot <- snapshots, snapshot.id in imports do
              if resource =
                   Repo.get_by(CalendarSyncResource,
                     binding_id: binding.id,
                     remote_resource_id: snapshot.id
                   ) do
                existing =
                  Repo.all(from eb in CalendarEventBinding, where: eb.resource_id == ^resource.id)

                for eb <- existing do
                  claimed = claims[claim_key(snapshot.id, eb.remote_component_key)]
                  if claimed && claimed != eb.event_id, do: Repo.rollback(:existing_mapping)
                  Repo.update!(Ecto.Changeset.change(eb, state: "enrolled"))
                end
              end
            end
          end

          Enum.each(
            Enum.filter(events, &(&1.id in uploads))
            |> Enum.sort_by(&{&1.recurrence_id not in [nil, ""], &1.id}),
            fn event ->
              if existing =
                   Repo.get_by(CalendarEventBinding, binding_id: binding.id, event_id: event.id) do
                Repo.update!(
                  Ecto.Changeset.change(existing,
                    state: "enrolled",
                    desired_revision: event.local_revision
                  )
                )

                resource = Repo.get!(CalendarSyncResource, existing.resource_id)

                if resource.status not in ["uncertain", "conflict"] and
                     event.local_revision > existing.acknowledged_revision do
                  Repo.update!(Ecto.Changeset.change(resource, status: "pending"))
                end
              else
                State.enroll!(binding, event)
              end
            end
          )

          Enum.each(
            Enum.filter(snapshots, &(&1.id in imports)),
            &apply_snapshot!(binding, &1, import: true, claims: claims)
          )

          State.enqueue!(binding)
          binding
        end,
        opts
      )
    end
  end

  defp validate_remote_preview(id, opts) do
    with %CalendarBinding{} = binding <- Repo.get(CalendarBinding, id),
         connection = Repo.get!(CalendarConnection, binding.connection_id),
         {:ok, %{complete: true} = batch} <-
           adapter(connection, opts).fetch_changes(binding, %{}, opts) do
      previous = binding.enrollment_manifest["resources"] || []

      identity = fn list ->
        Enum.map(list, fn r -> {r["id"], r["etag"], r["raw"]} end) |> Enum.sort()
      end

      if identity.(previous) == identity.(json_value(batch.resources)),
        do: :ok,
        else: {:error, :stale_preview}
    else
      nil -> {:error, :not_found}
      {:ok, _} -> {:error, :incomplete_batch}
      error -> error
    end
  end

  def pause(id), do: change_state(id, "paused")

  def resume(id) do
    transaction(fn ->
      b = lock_context!(id)
      if b.state == "detached", do: Repo.rollback(:detached)

      b =
        Repo.update!(
          Ecto.Changeset.change(b, state: "active", generation: b.generation + 1, last_error: nil)
        )

      State.enqueue!(b)
      b
    end)
  end

  def detach(id), do: change_state(id, "detached")
  def mark_unavailable(id, reason), do: change_state(id, "unavailable", inspect(reason))

  defp change_state(id, state, error \\ nil) do
    transaction(fn ->
      b = lock_context!(id)
      attrs = %{state: state, last_error: error, generation: b.generation + 1}

      attrs =
        if state == "detached",
          do: Map.put(attrs, :suppressed_at, DateTime.utc_now()),
          else: attrs

      Repo.update!(Ecto.Changeset.change(b, attrs))
    end)
  end

  def conflict_preview(id) do
    case Repo.get(CalendarEventBinding, id) do
      %CalendarEventBinding{conflict: conflict} = eb when is_map(conflict) ->
        event = Repo.get!(CalendarEvent, eb.event_id)
        resource = Repo.get!(CalendarSyncResource, eb.resource_id)

        {:ok,
         %{
           local: State.projection(event),
           remote: conflict["remote"],
           base: eb.base_projection,
           version: conflict_version(event, resource),
           targets:
             Enum.filter(
               list_bindings(event.calendar_id),
               &(&1.state in ["active", "paused", "unavailable"])
             )
         }}

      _ ->
        {:error, :not_found}
    end
  end

  def resolve_conflict(id, expected, choice)
      when choice in [:local, :remote, "local", "remote"] do
    eb = Repo.get(CalendarEventBinding, id)

    if eb do
      transaction(fn ->
        binding = lock_context!(eb.binding_id)
        eb = Repo.get!(CalendarEventBinding, id)
        event = Repo.get!(CalendarEvent, eb.event_id)
        resource = Repo.get!(CalendarSyncResource, eb.resource_id)

        unless eb.conflict && expected == conflict_version(event, resource),
          do: Repo.rollback(:stale_preview)

        remote = eb.conflict["remote"]
        fields = eb.conflict["fields"] || Map.keys(remote)
        attrs = if choice in [:remote, "remote"], do: event_attrs(remote), else: %{}

        event =
          Repo.update!(
            Ecto.Changeset.change(
              event,
              Map.put(attrs, :local_revision, event.local_revision + 1)
            )
          )

        eb
        |> Ecto.Changeset.change(
          conflict: nil,
          base_projection: remote,
          projection_fields: fields
        )
        |> Repo.update!()

        unresolved_siblings =
          Repo.exists?(
            from sibling in CalendarEventBinding,
              where: sibling.resource_id == ^resource.id and not is_nil(sibling.conflict)
          )

        resource
        |> Ecto.Changeset.change(
          base_raw: resource.remote_raw,
          etag: resource.remote_etag,
          status: if(unresolved_siblings, do: "conflict", else: "pending")
        )
        |> Repo.update!()

        calendar = Repo.get!(Calendar, binding.calendar_id)

        source =
          if choice in [:remote, "remote"],
            do: %{binding_id: binding.id, projection: remote, fields: fields},
            else: %{}

        State.stage_events!(calendar, [event], source: source)
        event
      end)
    else
      {:error, :not_found}
    end
  end

  @doc "Apply only complete, successfully fetched batches, with an optional lease fence."
  def apply_batch(binding_id, batch, opts \\ [])

  def apply_batch(binding_id, %{complete: true} = batch, opts) do
    with %CalendarBinding{} = binding <- Repo.get(CalendarBinding, binding_id),
         connection = Repo.get!(CalendarConnection, binding.connection_id),
         {:ok, decoded} <- decode_batch(adapter(connection, opts), batch, opts) do
      transaction(
        fn ->
          binding = lock_context!(binding_id)
          ensure_fence!(binding, opts)
          unless binding.state == "active", do: Repo.rollback(:disabled)
          Enum.each(decoded.resources, &apply_snapshot!(binding, &1, opts))

          if batch.mode == :full do
            seen = Enum.map(decoded.resources, & &1.id)

            resources =
              Repo.all(
                from r in CalendarSyncResource,
                  where: r.binding_id == ^binding.id and r.remote_presence == "present"
              )

            for resource <- resources, resource.remote_resource_id not in seen do
              apply_snapshot!(
                binding,
                %{
                  id: resource.remote_resource_id,
                  presence: :deleted,
                  components: [],
                  raw: nil,
                  etag: nil
                },
                opts
              )
            end
          end

          Repo.update!(
            Ecto.Changeset.change(binding,
              checkpoint: batch.checkpoint,
              synced_at: DateTime.utc_now(),
              last_error: nil
            )
          )
        end,
        opts
      )
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def apply_batch(_, _, _), do: {:error, :incomplete_batch}

  @doc "Leased read/reconcile/write pass; adapters never run under row locks."
  def run(id, generation, opts \\ []) do
    owner = Ecto.UUID.generate()

    with {:ok, binding} <- acquire(id, generation, owner),
         connection = Repo.get!(CalendarConnection, binding.connection_id) do
      adapter = adapter(connection, opts)
      opts = Keyword.merge(opts, lease_owner: owner, generation: generation)

      try do
        with :ok <- reconcile_pending(binding, connection, adapter, opts),
             :ok <- active_fence(id, owner, generation),
             {:ok, batch} <-
               adapter.fetch_changes(Repo.get!(CalendarBinding, id), binding.checkpoint, opts),
             {:ok, _} <- apply_batch(id, batch, opts),
             :ok <- dispatch_pending(binding, connection, adapter, opts) do
          {:ok, Repo.get!(CalendarBinding, id)}
        else
          {:error, reason} = error ->
            if reason in [:not_found, :container_missing, :forbidden],
              do: mark_unavailable(id, reason)

            if reason == :unauthorized,
              do: Repo.update!(Ecto.Changeset.change(connection, status: "reconnect_required"))

            error
        end
      after
        Repo.update_all(
          from(b in CalendarBinding, where: b.id == ^id and b.lease_owner == ^owner),
          set: [lease_owner: nil, lease_expires_at: nil]
        )

        notify()
      end
    end
  end

  def enqueue_due do
    transaction(fn ->
      bindings =
        Repo.all(
          from b in CalendarBinding,
            join: c in CalendarConnection,
            on: c.id == b.connection_id,
            where: b.state == "active" and c.status == "active",
            order_by: b.id
        )

      Enum.each(bindings, &State.enqueue!/1)
      length(bindings)
    end)
  end

  defp acquire(id, generation, owner) do
    transaction(fn ->
      b = lock_context!(id)
      c = Repo.get!(CalendarConnection, b.connection_id)

      cond do
        b.enrollment_manifest["identity_verification_required"] == true or
            b.enrollment_manifest["baseline_hydration_required"] == true ->
          Repo.rollback(:migration_review_required)

        b.generation != generation ->
          Repo.rollback(:stale)

        b.state != "active" or c.status != "active" ->
          Repo.rollback(:disabled)

        b.lease_expires_at && DateTime.compare(b.lease_expires_at, DateTime.utc_now()) == :gt ->
          Repo.rollback(:busy)

        true ->
          Repo.update!(
            Ecto.Changeset.change(b,
              lease_owner: owner,
              lease_expires_at: DateTime.add(DateTime.utc_now(), 300)
            )
          )
      end
    end)
  end

  defp reconcile_pending(binding, _connection, adapter, opts) do
    attempts =
      Repo.all(
        from a in CalendarSyncAttempt,
          join: r in CalendarSyncResource,
          on: r.id == a.resource_id,
          where: r.binding_id == ^binding.id and a.state in ^@unresolved,
          order_by: a.inserted_at
      )

    Enum.reduce_while(attempts, :ok, fn attempt, :ok ->
      resource = Repo.get!(CalendarSyncResource, attempt.resource_id)

      with :ok <- active_fence(binding.id, opts[:lease_owner], opts[:generation]),
           {:ok, snapshot} <- adapter.fetch_resource(resource, opts),
           {:ok, components} <- decode_snapshot(adapter, snapshot, opts) do
        cond do
          attempt_matches?(attempt, snapshot, components) ->
            settle_success(
              attempt,
              %{
                etag: Map.get(snapshot, :etag),
                raw: Map.get(snapshot, :raw),
                components: components
              },
              opts
            )

            {:cont, :ok}

          map_size(attempt.component_revisions || %{}) == 0 and legacy_matches?(attempt, snapshot) ->
            # Legacy counter was resource-scoped. Preserve proof without inventing event ACKs.
            settle_success(
              attempt,
              %{
                etag: Map.get(snapshot, :etag),
                raw: Map.get(snapshot, :raw),
                components: components
              },
              opts
            )

            {:cont, :ok}

          baseline_matches?(resource, snapshot, components) ->
            # Proven unchanged baseline/absence makes retry safe. The old request remains archived.
            finish_attempt(attempt, "failed", "reconciled unchanged baseline")
            {:cont, :ok}

          true ->
            finish_attempt(attempt, "conflict", "unknown outcome differs from sent and baseline")

            transaction(fn ->
              _binding = lock_context!(binding.id)
              resource = Repo.get!(CalendarSyncResource, resource.id)

              ebs =
                Repo.all(from eb in CalendarEventBinding, where: eb.resource_id == ^resource.id)

              Enum.each(ebs, fn eb ->
                event = Repo.get!(CalendarEvent, eb.event_id)
                c = Enum.find(components, &(&1.key == eb.remote_component_key))

                remote =
                  if c, do: c.projection, else: Map.put(eb.base_projection, "deleted", true)

                fields = if c, do: Map.get(c, :fields, Map.keys(remote)), else: Map.keys(remote)

                conflict = %{
                  "remote" => remote,
                  "base" => eb.base_projection,
                  "local" => State.projection(event),
                  "fields" => fields,
                  "reason" => "unknown outcome"
                }

                Repo.update!(Ecto.Changeset.change(eb, conflict: conflict))
              end)

              Repo.update!(
                Ecto.Changeset.change(resource,
                  status: "conflict",
                  remote_raw: snapshot[:raw],
                  remote_etag: snapshot[:etag]
                )
              )
            end)

            {:cont, :ok}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp dispatch_pending(binding, connection, adapter, opts) do
    resources =
      Repo.all(
        from r in CalendarSyncResource,
          where:
            r.binding_id == ^binding.id and r.status in ["pending", "failed"] and
              (is_nil(r.retry_at) or r.retry_at <= ^DateTime.utc_now()),
          order_by: r.id
      )

    resources =
      Enum.sort_by(resources, fn resource ->
        eb =
          Repo.one(
            from eb in CalendarEventBinding, where: eb.resource_id == ^resource.id, limit: 1
          )

        event = if eb, do: Repo.get!(CalendarEvent, eb.event_id)
        {event && event.recurrence_id not in [nil, ""], resource.id}
      end)

    Enum.reduce_while(resources, :ok, fn resource, :ok ->
      with :ok <- active_fence(binding.id, opts[:lease_owner], opts[:generation]),
           {:ok, prepared} <- prepare(binding.id, resource.id, connection, adapter, opts) do
        case prepared do
          nil ->
            {:cont, :ok}

          attempt ->
            # Mark before entering transport. Process death from here is an unknown outcome.
            with {:ok, sent} <-
                   transaction(fn ->
                     b = lock_context!(binding.id)
                     ensure_fence!(b, opts)
                     unless b.state == "active", do: Repo.rollback(:disabled)
                     current_connection = Repo.get!(CalendarConnection, b.connection_id)

                     unless current_connection.status == "active" and
                              current_connection.generation == attempt.connection_generation,
                            do: Repo.rollback(:stale)

                     Repo.get!(CalendarSyncAttempt, attempt.id)
                     |> Ecto.Changeset.change(
                       state: "dispatched",
                       dispatched_at: DateTime.utc_now()
                     )
                     |> Repo.update!()
                   end) do
              result = adapter.execute(sent, connection, opts)

              case result do
                {:ok, response} ->
                  settle_success(sent, response, opts)

                {:error, reason} when reason in [:unknown, :outcome_unknown] ->
                  finish_attempt(sent, "uncertain", inspect(reason))

                {:error, :conflict} ->
                  finish_attempt(sent, "conflict", "precondition failed")

                {:error, {:rate_limited, seconds}} when is_integer(seconds) and seconds >= 0 ->
                  finish_attempt(sent, "failed", "rate_limited")

                  Repo.update!(
                    Ecto.Changeset.change(Repo.get!(CalendarSyncResource, sent.resource_id),
                      retry_at: DateTime.add(DateTime.utc_now(), seconds)
                    )
                  )

                {:error, reason} when reason in [:forbidden, :read_only, :unsupported] ->
                  finish_attempt(sent, "failed", inspect(reason))

                  transaction(fn ->
                    lock_context!(binding.id)
                    r = Repo.get!(CalendarSyncResource, sent.resource_id)

                    Repo.update!(
                      Ecto.Changeset.change(r, status: "limited", last_error: inspect(reason))
                    )

                    Repo.update_all(
                      from(eb in CalendarEventBinding, where: eb.resource_id == ^r.id),
                      set: [state: "limited", last_error: inspect(reason)]
                    )
                  end)

                {:error, :unauthorized} ->
                  finish_attempt(sent, "failed", "unauthorized")
                  Repo.update!(Ecto.Changeset.change(connection, status: "reconnect_required"))

                {:error, reason} ->
                  finish_attempt(sent, "failed", inspect(reason))
              end

              # Per-resource failure does not prevent independent resources/targets progressing.
              {:cont, :ok}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      else
        {:error, reason} when reason in [:limited, :conflict, :uncertain] -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp prepare(binding_id, resource_id, connection, adapter, opts) do
    with :ok <- resolve_target(binding_id, resource_id, adapter, opts) do
      prepare_resolved(binding_id, resource_id, connection, adapter, opts)
    end
  end

  defp resolve_target(binding_id, resource_id, adapter, opts) do
    if function_exported?(adapter, :resolve_target, 3) do
      binding = Repo.get!(CalendarBinding, binding_id)
      resource = Repo.get!(CalendarSyncResource, resource_id)

      eb =
        Repo.one(from eb in CalendarEventBinding, where: eb.resource_id == ^resource_id, limit: 1)

      event = if eb, do: Repo.get!(CalendarEvent, eb.event_id)

      master_eb =
        if event && event.recurrence_id not in [nil, ""] do
          Repo.one(
            from eb in CalendarEventBinding,
              join: e in assoc(eb, :event),
              where:
                eb.binding_id == ^binding_id and e.series_id == ^event.series_id and
                  e.recurrence_id == "",
              limit: 1
          )
        end

      metadata =
        if master_eb do
          master = Repo.get!(CalendarEvent, master_eb.event_id)

          Map.merge(resource.provider_metadata || %{}, %{
            "master_base_projection" => master_eb.base_projection,
            "master_uid" => master.uid
          })
        else
          resource.provider_metadata || %{}
        end

      resource = %{resource | provider_metadata: metadata}

      with :ok <- active_fence(binding_id, opts[:lease_owner], opts[:generation]),
           {:ok, snapshot} <- adapter.resolve_target(binding, resource, opts) do
        if is_nil(snapshot) do
          :ok
        else
          with {:ok, [component]} <- adapter.decode(snapshot, opts) do
            expected =
              snapshot.metadata[:original_projection] || snapshot.metadata["original_projection"]

            fields = Map.get(component, :fields, Map.keys(component.projection))

            case transaction(fn ->
                   b = lock_context!(binding_id)
                   ensure_fence!(b, opts)
                   current = Repo.get!(CalendarEvent, event.id)

                   unless current.local_revision == event.local_revision,
                     do: Repo.rollback(:stale)

                   r = Repo.get!(CalendarSyncResource, resource_id)
                   eb = Repo.get!(CalendarEventBinding, eb.id)

                   matches =
                     is_map(expected) and
                       State.equivalent?(expected, component.projection, fields)

                   attrs = %{
                     remote_resource_id: snapshot.id,
                     href: snapshot.href,
                     base_raw: snapshot.raw,
                     etag: snapshot.etag,
                     remote_raw: snapshot.raw,
                     remote_etag: snapshot.etag,
                     remote_presence: "present",
                     provider_metadata: Map.merge(metadata, json_value(snapshot.metadata)),
                     status: if(matches, do: "pending", else: "conflict")
                   }

                   Repo.update!(Ecto.Changeset.change(r, attrs))

                   if matches do
                     Repo.update!(
                       Ecto.Changeset.change(eb,
                         base_projection: component.projection,
                         projection_fields: fields
                       )
                     )

                     :ok
                   else
                     conflict = %{
                       "base" => expected || %{},
                       "remote" => component.projection,
                       "local" => State.projection(current),
                       "fields" => fields,
                       "reason" => "remote instance already modified"
                     }

                     Repo.update!(Ecto.Changeset.change(eb, conflict: conflict))
                     :conflict
                   end
                 end) do
              {:ok, :ok} -> :ok
              {:ok, :conflict} -> {:error, :conflict}
              error -> error
            end
          else
            {:ok, _} -> {:error, :invalid_instance}
            error -> error
          end
        end
      end
    else
      :ok
    end
  end

  defp prepare_resolved(binding_id, resource_id, connection, adapter, opts) do
    # Pure serialization can be performed outside the transaction; revalidate exact vectors inside.
    resource = Repo.get!(CalendarSyncResource, resource_id)

    ebs =
      Repo.all(
        from eb in CalendarEventBinding,
          where: eb.resource_id == ^resource.id and eb.state != "suppressed",
          order_by: eb.event_id
      )

    components =
      Enum.map(ebs, fn eb ->
        event = Repo.get!(CalendarEvent, eb.event_id)
        %{key: eb.remote_component_key, event: event, projection: State.projection(event)}
      end)

    operation = if Enum.all?(components, & &1.projection["deleted"]), do: "delete", else: "upsert"
    binding = Repo.get!(CalendarBinding, binding_id)

    with :ok <- writable(binding, resource, operation),
         {:ok, destination} <- destination(adapter, binding, resource, opts),
         {:ok, payload} <- encode(adapter, resource, components, operation, opts) do
      transaction(fn ->
        binding = lock_context!(binding_id)
        ensure_fence!(binding, opts)
        resource = Repo.get!(CalendarSyncResource, resource_id)

        resource =
          if connection.provider == "icloud" and function_exported?(adapter, :destination, 2),
            do:
              Repo.update!(
                Ecto.Changeset.change(resource,
                  href: destination,
                  remote_resource_id: destination
                )
              ),
            else: resource

        ebs =
          Repo.all(
            from eb in CalendarEventBinding,
              where: eb.resource_id == ^resource.id and eb.state != "suppressed",
              order_by: eb.event_id
          )

        cond do
          binding.direction == "inbound" or binding.capabilities["write"] == false ->
            Repo.rollback(:limited)

          resource.status == "conflict" or Enum.any?(ebs, &(not is_nil(&1.conflict))) ->
            Repo.rollback(:conflict)

          Repo.exists?(
            from a in CalendarSyncAttempt,
              where: a.resource_id == ^resource.id and a.state in ^@unresolved
          ) ->
            Repo.rollback(:uncertain)

          Enum.all?(ebs, &(&1.desired_revision <= &1.acknowledged_revision)) ->
            nil

          true ->
            vector = Map.new(components, &{&1.event.id, &1.event.local_revision})

            unless Enum.all?(ebs, fn eb ->
                     Repo.get!(CalendarEvent, eb.event_id).local_revision == vector[eb.event_id]
                   end),
                   do: Repo.rollback(:stale)

            if operation == "delete" and resource.remote_presence != "present" and
                 is_nil(resource.base_raw) do
              Enum.each(ebs, fn eb ->
                Repo.update!(
                  Ecto.Changeset.change(eb, acknowledged_revision: vector[eb.event_id])
                )
              end)

              Repo.update!(Ecto.Changeset.change(resource, status: "synced"))
              nil
            else
              precondition =
                if resource.etag,
                  do: %{"if_match" => resource.etag},
                  else: %{"if_none_match" => "*"}

              Repo.insert!(
                Ecto.Changeset.change(%CalendarSyncAttempt{},
                  resource_id: resource.id,
                  connection_generation: connection.generation,
                  binding_generation: binding.generation,
                  operation: operation,
                  destination: destination,
                  payload: payload,
                  precondition: precondition,
                  component_revisions: vector,
                  sent_projections: Map.new(components, &{&1.event.id, &1.projection}),
                  state: "prepared"
                )
              )
            end
        end
      end)
    else
      {:error, reason} ->
        Repo.update!(
          Ecto.Changeset.change(resource, status: "limited", last_error: inspect(reason))
        )

        {:error, :limited}
    end
  end

  defp writable(binding, resource, operation) do
    capability =
      cond do
        operation == "delete" -> "delete"
        resource.remote_presence == "present" or not is_nil(resource.base_raw) -> "update"
        true -> "create"
      end

    if binding.direction == "inbound" or binding.capabilities["write"] == false or
         binding.capabilities[capability] == false,
       do: {:error, {:capability_required, capability}},
       else: :ok
  end

  defp destination(adapter, binding, resource, opts) do
    cond do
      function_exported?(adapter, :destination, 3) -> adapter.destination(binding, resource, opts)
      function_exported?(adapter, :destination, 2) -> adapter.destination(binding, resource)
      true -> {:ok, resource.href || resource.remote_resource_id}
    end
  end

  defp encode(adapter, resource, components, "delete", opts) do
    if function_exported?(adapter, :validate_delete, 3) do
      with :ok <- adapter.validate_delete(resource, components, opts), do: {:ok, nil}
    else
      {:ok, nil}
    end
  end

  defp encode(adapter, resource, components, _, opts),
    do: adapter.encode(resource, components, opts)

  defp settle_success(attempt, response, _opts) do
    resource = Repo.get!(CalendarSyncResource, attempt.resource_id)

    transaction(fn ->
      _binding = lock_context!(resource.binding_id)
      attempt = Repo.get!(CalendarSyncAttempt, attempt.id)
      resource = Repo.get!(CalendarSyncResource, attempt.resource_id)

      Enum.each(attempt.component_revisions || %{}, fn {event_id, revision} ->
        if eb = Repo.get_by(CalendarEventBinding, resource_id: resource.id, event_id: event_id) do
          # ACK exact sent version, never current canonical content or current desired revision.
          if revision >= eb.acknowledged_revision do
            Repo.update!(
              Ecto.Changeset.change(eb,
                acknowledged_revision: revision,
                base_projection: attempt.sent_projections[event_id] || eb.base_projection
              )
            )
          end
        end
      end)

      if map_size(attempt.component_revisions || %{}) == 0 do
        # A legacy resource counter cannot certify any canonical revision. A
        # proven read-back can still establish its projection baseline safely.
        components = Map.get(response, :components, [])
        ebs = Repo.all(from eb in CalendarEventBinding, where: eb.resource_id == ^resource.id)

        for eb <- ebs do
          component = Enum.find(components, &(&1.key == eb.remote_component_key))

          projection =
            cond do
              component -> component.projection
              attempt.operation == "delete" -> Map.put(eb.base_projection, "deleted", true)
              true -> nil
            end

          if projection do
            fields =
              if component,
                do: Map.get(component, :fields, Map.keys(projection)),
                else: eb.projection_fields

            Repo.update!(
              Ecto.Changeset.change(eb, base_projection: projection, projection_fields: fields)
            )
          end
        end
      end

      limited =
        Repo.exists?(
          from eb in CalendarEventBinding,
            where: eb.resource_id == ^resource.id and eb.state == "limited"
        )

      outstanding =
        Repo.exists?(
          from eb in CalendarEventBinding,
            where:
              eb.resource_id == ^resource.id and eb.desired_revision > eb.acknowledged_revision
        )

      presence = if attempt.operation == "delete", do: "deleted", else: "present"

      newer_attempt =
        Repo.exists?(
          from a in CalendarSyncAttempt,
            where:
              a.resource_id == ^resource.id and a.inserted_at > ^attempt.inserted_at and
                a.state in ["prepared", "dispatched", "uncertain", "succeeded"]
        )

      unless newer_attempt do
        Repo.update!(
          Ecto.Changeset.change(resource,
            base_raw: Map.get(response, :raw) || attempt.payload,
            remote_raw: Map.get(response, :raw) || attempt.payload,
            etag: Map.get(response, :etag),
            remote_etag: Map.get(response, :etag),
            remote_presence: presence,
            status:
              if(outstanding, do: "pending", else: if(limited, do: "limited", else: "synced")),
            last_error: nil,
            retry_at: nil
          )
        )
      end

      Repo.update!(
        Ecto.Changeset.change(attempt,
          state: "succeeded",
          response_etag: Map.get(response, :etag),
          response_raw: Map.get(response, :raw),
          completed_at: DateTime.utc_now()
        )
      )
    end)
  end

  defp finish_attempt(attempt, state, reason) do
    resource = Repo.get!(CalendarSyncResource, attempt.resource_id)

    transaction(fn ->
      lock_context!(resource.binding_id)

      Repo.get!(CalendarSyncAttempt, attempt.id)
      |> Ecto.Changeset.change(
        state: state,
        last_error: reason,
        completed_at: if(state == "uncertain", do: nil, else: DateTime.utc_now())
      )
      |> Repo.update!()

      Repo.get!(CalendarSyncResource, resource.id)
      |> Ecto.Changeset.change(status: state_for_attempt(state), last_error: reason)
      |> Repo.update!()
    end)
  end

  defp state_for_attempt("uncertain"), do: "uncertain"
  defp state_for_attempt("conflict"), do: "conflict"
  defp state_for_attempt(_), do: "failed"

  defp apply_snapshot!(binding, snapshot, opts) do
    resource =
      Repo.get_by(CalendarSyncResource, binding_id: binding.id, remote_resource_id: snapshot.id)

    historical = Enum.map((binding.enrollment_manifest || %{})["resources"] || [], & &1["id"])

    importing =
      Keyword.get(opts, :import, false) or
        (binding.enrollment_manifest["confirmed_at"] != nil and snapshot.id not in historical)

    cond do
      is_nil(resource) and not importing ->
        :ignored_unenrolled

      is_nil(resource) and snapshot.presence == :deleted ->
        :ignored_absent

      true ->
        resource =
          resource ||
            Repo.insert!(
              Ecto.Changeset.change(%CalendarSyncResource{},
                binding_id: binding.id,
                remote_resource_id: snapshot.id,
                href: Map.get(snapshot, :href),
                status: "synced"
              )
            )

        ebs =
          Repo.all(
            from eb in CalendarEventBinding,
              where: eb.resource_id == ^resource.id and eb.state != "suppressed",
              order_by: eb.event_id
          )

        components = Map.get(snapshot, :components, [])
        seen = Enum.map(components, & &1.key)

        Enum.each(components, fn component ->
          eb = Enum.find(ebs, &(&1.remote_component_key == component.key))

          eb =
            if is_nil(eb) and length(ebs) == 1 and length(components) == 1 and
                 Repo.get!(CalendarConnection, binding.connection_id).provider == "google" do
              Repo.update!(Ecto.Changeset.change(hd(ebs), remote_component_key: component.key))
            else
              eb
            end

          cond do
            eb -> reconcile_component!(binding, resource, eb, component, snapshot)
            importing -> import_component!(binding, resource, component, snapshot, opts)
            # New remote components in a previously enrolled resource have proven source identity.
            true -> import_component!(binding, resource, component, snapshot, opts)
          end
        end)

        refreshed_ebs =
          Repo.all(
            from eb in CalendarEventBinding,
              where: eb.resource_id == ^resource.id and eb.state != "suppressed"
          )

        for eb <- refreshed_ebs,
            snapshot.presence == :deleted or eb.remote_component_key not in seen do
          reconcile_component!(
            binding,
            resource,
            eb,
            %{
              key: eb.remote_component_key,
              projection: Map.put(eb.base_projection, "deleted", true),
              fields: Enum.uniq(eb.projection_fields ++ ["deleted"])
            },
            snapshot
          )
        end

        resource = Repo.get!(CalendarSyncResource, resource.id)

        conflicted =
          Repo.exists?(
            from eb in CalendarEventBinding,
              where: eb.resource_id == ^resource.id and not is_nil(eb.conflict)
          )

        limited =
          Repo.exists?(
            from eb in CalendarEventBinding,
              where: eb.resource_id == ^resource.id and eb.state == "limited"
          )

        outstanding =
          Repo.exists?(
            from eb in CalendarEventBinding,
              where:
                eb.resource_id == ^resource.id and eb.desired_revision > eb.acknowledged_revision
          )

        attrs = %{
          remote_raw: Map.get(snapshot, :raw),
          remote_etag: Map.get(snapshot, :etag),
          remote_presence: Atom.to_string(snapshot.presence)
        }

        attrs =
          if conflicted,
            do: Map.put(attrs, :status, "conflict"),
            else:
              Map.merge(attrs, %{
                base_raw: Map.get(snapshot, :raw),
                etag: Map.get(snapshot, :etag),
                status:
                  if(outstanding, do: "pending", else: if(limited, do: "limited", else: "synced"))
              })

        Repo.update!(Ecto.Changeset.change(resource, attrs))
    end
  end

  defp reconcile_component!(binding, resource, eb, component, snapshot) do
    event = Repo.get!(CalendarEvent, eb.event_id)
    current = State.projection(event)
    base = eb.base_projection || %{}
    deleted = component.projection["deleted"] == true
    remote = if deleted, do: Map.merge(base, component.projection), else: component.projection
    fields = Map.get(component, :fields, Map.keys(remote))
    fields = if deleted, do: Enum.uniq(fields ++ eb.projection_fields), else: fields

    known_attempt =
      Repo.all(
        from a in CalendarSyncAttempt,
          where: a.resource_id == ^resource.id,
          order_by: [desc: a.inserted_at]
      )
      |> Enum.find(fn a ->
        sent = a.sent_projections[event.id]
        sent && State.equivalent?(sent, remote, fields)
      end)

    cond do
      State.equivalent?(current, remote, fields) ->
        Repo.update!(
          Ecto.Changeset.change(eb,
            base_projection: remote,
            projection_fields: fields,
            acknowledged_revision: event.local_revision,
            desired_revision: event.local_revision,
            state:
              if(State.projection_limit(event, fields) == [], do: "enrolled", else: "limited"),
            last_error:
              if(State.projection_limit(event, fields) == [],
                do: nil,
                else:
                  "unsupported projection: " <>
                    Enum.join(State.projection_limit(event, fields), ", ")
              ),
            conflict: nil
          )
        )

      known_attempt ->
        revision = known_attempt.component_revisions[event.id] || eb.acknowledged_revision

        Repo.update!(
          Ecto.Changeset.change(eb,
            base_projection: remote,
            projection_fields: fields,
            acknowledged_revision: max(eb.acknowledged_revision, revision)
          )
        )

      State.equivalent?(base, remote, fields) ->
        :unchanged_remote

      State.equivalent?(base, current, fields) and is_nil(eb.conflict) and
          not (deleted and eb.desired_revision > eb.acknowledged_revision) ->
        event =
          event
          |> Ecto.Changeset.change(
            Map.put(event_attrs(remote), :local_revision, event.local_revision + 1)
          )
          |> Repo.update!()

        State.stage_events!(Repo.get!(Calendar, binding.calendar_id), [event],
          source: %{binding_id: binding.id, projection: remote, fields: fields}
        )

      true ->
        conflict = %{
          "remote" => remote,
          "base" => base,
          "local" => current,
          "fields" => fields,
          "local_revision" => event.local_revision,
          "remote_etag" => Map.get(snapshot, :etag)
        }

        Repo.update!(Ecto.Changeset.change(eb, conflict: conflict))
    end

    record_coverage!(
      Repo.get!(CalendarEventBinding, eb.id),
      Repo.get!(CalendarEvent, event.id),
      component
    )
  end

  defp import_component!(binding, resource, component, snapshot, opts) do
    claims = Keyword.get(opts, :claims, %{})
    claimed = claims[claim_key(resource.remote_resource_id, component.key)]
    metadata = Map.get(component, :metadata, %{})
    projection = component.projection
    fields = Map.get(component, :fields, Map.keys(projection))

    if claimed do
      event = Repo.get!(CalendarEvent, claimed)
      unless event.calendar_id == binding.calendar_id, do: Repo.rollback(:invalid_claim)

      if Repo.get_by(CalendarEventBinding, binding_id: binding.id, event_id: event.id),
        do: Repo.rollback(:already_enrolled)

      eb = State.enroll!(binding, event, resource: resource, key: component.key)
      # A claim links identities, but never chooses a winner implicitly.
      reconcile_component!(binding, resource, eb, component, snapshot)
    else
      # Series identity may be reused only within this exact remote source's proven grouping.
      series_key = metadata["series_key"] || metadata[:series_key]
      series_id = proven_series(binding.id, series_key) || Ecto.UUID.generate()

      attrs =
        event_attrs(projection)
        |> Map.merge(%{
          calendar_id: binding.calendar_id,
          uid: metadata["uid"] || metadata[:uid] || Ecto.UUID.generate(),
          series_id: series_id,
          local_revision: 1,
          read_only: binding.direction == "inbound"
        })

      event = Repo.insert!(Ecto.Changeset.change(%CalendarEvent{}, attrs))
      eb = State.enroll!(binding, event, resource: resource, key: component.key)

      Repo.update!(
        Ecto.Changeset.change(eb,
          acknowledged_revision: 1,
          base_projection: projection,
          projection_fields: fields
        )
      )

      if series_key do
        r = Repo.get!(CalendarSyncResource, resource.id)

        Repo.update!(
          Ecto.Changeset.change(r,
            provider_metadata:
              Map.put(
                r.provider_metadata || %{},
                "series_keys",
                Map.put((r.provider_metadata || %{})["series_keys"] || %{}, series_key, series_id)
              )
          )
        )
      end

      State.stage_events!(Repo.get!(Calendar, binding.calendar_id), [event],
        source: %{binding_id: binding.id, projection: projection, fields: fields}
      )

      record_coverage!(Repo.get!(CalendarEventBinding, eb.id), event, component)
    end
  end

  defp record_coverage!(eb, event, component) do
    fields = Map.get(component, :fields, Map.keys(component.projection))
    metadata = Map.get(component, :metadata, %{})
    limits = Map.get(metadata, :capability_limits, Map.get(metadata, "capability_limits", []))
    missing = State.projection_limit(event, fields)

    errors =
      if event.deleted_at,
        do: [],
        else: limits ++ Enum.map(missing, &("unsupported projection: " <> &1))

    Repo.update!(
      Ecto.Changeset.change(eb,
        state: if(errors == [], do: "enrolled", else: "limited"),
        last_error: if(errors == [], do: nil, else: Enum.join(errors, ", "))
      )
    )
  end

  defp proven_series(_, nil), do: nil

  defp proven_series(binding_id, key) do
    Repo.all(from r in CalendarSyncResource, where: r.binding_id == ^binding_id)
    |> Enum.find_value(fn r -> get_in(r.provider_metadata || %{}, ["series_keys", key]) end)
  end

  defp event_attrs(projection) do
    projection
    |> Map.take(State.fields() -- ["deleted"])
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
    |> then(fn attrs ->
      if Map.has_key?(projection, "deleted"),
        do:
          Map.put(
            attrs,
            :deleted_at,
            if(projection["deleted"], do: DateTime.utc_now(), else: nil)
          ),
        else: attrs
    end)
  end

  defp decode_batch(adapter, batch, opts) do
    Enum.reduce_while(batch.resources, {:ok, []}, fn snapshot, {:ok, resources} ->
      case decode_snapshot(adapter, snapshot, opts) do
        {:ok, components} ->
          {:cont, {:ok, [Map.put(snapshot, :components, components) | resources]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resources} -> {:ok, Map.put(batch, :resources, Enum.reverse(resources))}
      error -> error
    end
  end

  defp decode_snapshot(_, %{presence: :deleted}, _), do: {:ok, []}
  defp decode_snapshot(adapter, snapshot, opts), do: adapter.decode(snapshot, opts)

  defp attempt_matches?(%{operation: "delete"}, %{presence: :deleted}, _), do: true

  defp attempt_matches?(attempt, %{presence: :present}, components) do
    map_size(attempt.component_revisions || %{}) > 0 and
      Enum.all?(attempt.sent_projections, fn {event_id, projection} ->
        eb =
          Repo.get_by(CalendarEventBinding, resource_id: attempt.resource_id, event_id: event_id)

        if projection["deleted"] do
          not Enum.any?(components, &(&1.key == eb.remote_component_key))
        else
          Enum.any?(components, fn c ->
            c.key == eb.remote_component_key and
              State.equivalent?(
                projection,
                c.projection,
                Map.get(c, :fields, Map.keys(c.projection))
              )
          end)
        end
      end)
  end

  defp attempt_matches?(_, _, _), do: false

  defp baseline_matches?(resource, %{presence: :deleted}, _),
    do: is_nil(resource.base_raw) and resource.remote_presence != "present"

  defp baseline_matches?(resource, snapshot, components) do
    ebs = Repo.all(from eb in CalendarEventBinding, where: eb.resource_id == ^resource.id)

    snapshot.presence == :present and not is_nil(resource.base_raw) and
      Enum.all?(ebs, fn eb ->
        Enum.any?(components, fn c ->
          c.key == eb.remote_component_key and
            State.equivalent?(eb.base_projection, c.projection, eb.projection_fields)
        end)
      end)
  end

  defp legacy_matches?(attempt, snapshot),
    do: attempt.payload && snapshot[:raw] == attempt.payload

  defp conflict_version(event, resource),
    do: %{
      "local_revision" => event.local_revision,
      "remote_etag" => resource.remote_etag,
      "resource_updated_at" => DateTime.to_iso8601(resource.updated_at)
    }

  defp claim_key(resource, component), do: resource <> "/" <> component

  defp adapter(%{provider: provider}, opts),
    do:
      Keyword.get(opts, :adapter) ||
        if(provider == "google",
          do: Manifold.Connectors.CalendarSync.Google,
          else: Manifold.Connectors.CalendarSync.ICloud
        )

  defp lock_calendar!(id) do
    Repo.one(from c in Calendar, where: c.id == ^id, lock: "FOR UPDATE") ||
      Repo.rollback(:not_found)
  end

  defp lock_context!(id) do
    observed = Repo.get(CalendarBinding, id) || Repo.rollback(:not_found)
    if observed.calendar_id, do: lock_calendar!(observed.calendar_id)

    bindings =
      if observed.calendar_id do
        Repo.all(
          from b in CalendarBinding,
            where: b.calendar_id == ^observed.calendar_id,
            order_by: b.id,
            lock: "FOR UPDATE"
        )
      else
        Repo.all(from b in CalendarBinding, where: b.id == ^id, lock: "FOR UPDATE")
      end

    ids = Enum.map(bindings, & &1.id)

    Repo.all(
      from r in CalendarSyncResource,
        where: r.binding_id in ^ids,
        order_by: r.id,
        lock: "FOR UPDATE"
    )

    if observed.calendar_id,
      do:
        Repo.all(
          from e in CalendarEvent,
            where: e.calendar_id == ^observed.calendar_id,
            order_by: e.id,
            lock: "FOR UPDATE"
        )

    Enum.find(bindings, &(&1.id == id)) || Repo.rollback(:stale)
  end

  defp ensure_fence!(binding, opts) do
    if opts[:lease_owner] &&
         (binding.lease_owner != opts[:lease_owner] || binding.generation != opts[:generation] ||
            is_nil(binding.lease_expires_at) ||
            DateTime.compare(binding.lease_expires_at, DateTime.utc_now()) != :gt),
       do: Repo.rollback(:stale)
  end

  defp active_fence(id, owner, generation) do
    b = Repo.get!(CalendarBinding, id)
    c = Repo.get!(CalendarConnection, b.connection_id)

    cond do
      b.state != "active" or c.status != "active" ->
        {:error, :disabled}

      b.lease_owner != owner or b.generation != generation or is_nil(b.lease_expires_at) or
          DateTime.compare(b.lease_expires_at, DateTime.utc_now()) != :gt ->
        {:error, :stale}

      true ->
        :ok
    end
  end

  defp transaction(fun, _opts \\ []) do
    case Repo.transaction(fun) do
      {:ok, result} ->
        notify()
        {:ok, result}

      error ->
        error
    end
  end

  defp notify do
    if Process.whereis(Manifold.PubSub),
      do:
        apply(Module.concat(Phoenix, PubSub), :broadcast, [
          Manifold.PubSub,
          "calendar:changes",
          :calendar_changed
        ])

    :ok
  end

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp snapshot_from_json(map) do
    %{
      id: map["id"],
      href: map["href"],
      raw: map["raw"],
      etag: map["etag"],
      presence: if(map["presence"] == "deleted", do: :deleted, else: :present),
      metadata: map["metadata"] || %{},
      components:
        Enum.map(map["components"] || [], fn c ->
          %{
            key: c["key"],
            projection: c["projection"],
            fields: c["fields"],
            metadata: c["metadata"] || %{}
          }
        end)
    }
  end
end
