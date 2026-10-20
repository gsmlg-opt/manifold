defmodule Manifold.Data.CalendarSyncState do
  @moduledoc "Transaction-local, provider-independent calendar outbox staging."
  import Ecto.Query

  alias Manifold.Data.Schema.{
    CalendarBinding,
    CalendarConnection,
    CalendarEventBinding,
    CalendarSyncResource
  }

  alias Manifold.Repo

  @field_atoms ~w(summary description location starts_at ends_at timezone all_day recurrence_id recurrence_timezone recurrence_rules recurrence_dates excluded_dates time_kind reminders)a
  @fields Enum.map(@field_atoms, &Atom.to_string/1)
  def fields, do: @fields ++ ["deleted"]

  def notify do
    if Process.whereis(Manifold.PubSub),
      do:
        apply(Module.concat(Phoenix, PubSub), :broadcast, [
          Manifold.PubSub,
          "calendar:changes",
          :calendar_changed
        ])

    :ok
  end

  def projection(event) do
    Map.new(@field_atoms, fn field -> {Atom.to_string(field), Map.get(event, field)} end)
    |> Map.put("deleted", not is_nil(event.deleted_at))
  end

  def equivalent?(left, right, fields),
    do: Map.take(left || %{}, fields) == Map.take(right || %{}, fields)

  def projection_limit(event, covered_fields) do
    projection(event)
    |> Enum.filter(fn {field, value} ->
      field not in covered_fields and value not in [nil, "", [], false]
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc "Call inside the same transaction as the canonical event mutation."
  def stage_events!(calendar, events, opts \\ []) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "calendar staging requires a transaction")

    bindings =
      Repo.all(
        from b in CalendarBinding,
          where: b.calendar_id == ^calendar.id and b.state in ["active", "paused", "unavailable"],
          order_by: b.id,
          lock: "FOR UPDATE"
      )

    source = Keyword.get(opts, :source, %{}) || %{}

    Enum.each(bindings, fn binding ->
      Enum.each(Enum.sort_by(events, &{&1.recurrence_id not in [nil, ""], &1.id}), fn event ->
        existing = Repo.get_by(CalendarEventBinding, binding_id: binding.id, event_id: event.id)
        eb = existing || if(enroll_new?(binding, event), do: enroll!(binding, event))

        if eb && eb.state != "suppressed" do
          source? =
            Map.get(source, :binding_id) == binding.id ||
              Map.get(source, "binding_id") == binding.id

          attrs = %{desired_revision: event.local_revision}

          attrs =
            if source? do
              projection =
                Map.get(source, :projection, Map.get(source, "projection", projection(event)))

              fields = Map.get(source, :fields, Map.get(source, "fields", Map.keys(projection)))

              Map.merge(attrs, %{
                acknowledged_revision: event.local_revision,
                base_projection: projection,
                projection_fields: fields,
                state: if(projection_limit(event, fields) == [], do: "enrolled", else: "limited"),
                last_error:
                  if(projection_limit(event, fields) == [],
                    do: nil,
                    else:
                      "unsupported projection: " <>
                        Enum.join(projection_limit(event, fields), ", ")
                  )
              })
            else
              attrs
            end

          eb = Repo.update!(Ecto.Changeset.change(eb, attrs))
          resource = Repo.get!(CalendarSyncResource, eb.resource_id)

          status =
            cond do
              resource.status in ["uncertain", "conflict"] -> resource.status
              binding.direction == "inbound" or eb.state == "limited" -> "limited"
              eb.desired_revision > eb.acknowledged_revision -> "pending"
              true -> resource.status
            end

          Repo.update!(Ecto.Changeset.change(resource, status: status))
        end
      end)

      if binding.state == "active", do: enqueue!(binding)
    end)

    events
  end

  def enroll!(binding, event, opts \\ []) do
    resource = Keyword.get(opts, :resource) || resource_for!(binding, event)
    key = Keyword.get(opts, :key, event.uid <> <<31>> <> (event.recurrence_id || ""))

    Repo.insert!(
      Ecto.Changeset.change(%CalendarEventBinding{},
        binding_id: binding.id,
        event_id: event.id,
        resource_id: resource.id,
        remote_component_key: key,
        desired_revision: event.local_revision,
        acknowledged_revision: 0,
        base_projection: %{},
        projection_fields: fields(),
        state: "enrolled"
      )
    )
  end

  def enqueue!(binding) do
    args = %{"binding_id" => binding.id, "generation" => binding.generation}
    worker = "Manifold.Connectors.Jobs.SyncCalendar"

    unless Repo.exists?(
             from j in Styx.Job,
               where:
                 j.worker == ^worker and
                   j.state in ["available", "scheduled", "executing", "retryable"] and
                   fragment("? @> ?", j.args, type(^args, :map))
           ) do
      args |> Styx.Job.new(worker: worker, queue: :connectors, max_attempts: 10) |> Repo.insert!()
    end

    :ok
  end

  defp enroll_new?(binding, event) do
    case Map.get(binding.enrollment_manifest || %{}, "confirmed_at") do
      nil ->
        false

      timestamp ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, confirmed_at, _} -> DateTime.compare(event.inserted_at, confirmed_at) != :lt
          _ -> false
        end
    end
  end

  defp resource_for!(binding, event) do
    # A source-proven canonical series shares one ICS resource. UID is not identity.
    connection = Repo.get!(CalendarConnection, binding.connection_id)

    existing =
      if event.series_id && connection.provider == "icloud" do
        Repo.one(
          from eb in CalendarEventBinding,
            join: e in assoc(eb, :event),
            where: eb.binding_id == ^binding.id and e.series_id == ^event.series_id,
            select: eb.resource_id,
            limit: 1
        )
      end

    if existing do
      Repo.get!(CalendarSyncResource, existing)
    else
      # Identity is reserved durably before dispatch; retries reuse this destination.
      remote_id = String.replace(Ecto.UUID.generate(), "-", "")

      metadata =
        if connection.provider == "google" and event.recurrence_id not in [nil, ""] do
          master =
            Repo.one(
              from eb in CalendarEventBinding,
                join: e in assoc(eb, :event),
                join: r in assoc(eb, :resource),
                where:
                  eb.binding_id == ^binding.id and e.series_id == ^event.series_id and
                    e.recurrence_id == "",
                select: r.remote_resource_id,
                limit: 1
            )

          %{"master_remote_id" => master, "original_slot" => event.recurrence_id}
        else
          %{}
        end

      Repo.insert!(
        Ecto.Changeset.change(%CalendarSyncResource{},
          binding_id: binding.id,
          remote_resource_id: remote_id,
          status: "pending",
          remote_presence: "unknown",
          provider_metadata: metadata
        )
      )
    end
  end
end
