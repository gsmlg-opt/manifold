defmodule Manifold.Connectors.CalendarMigrationTest do
  use Manifold.DataCase, async: true
  alias Manifold.{Calendars, Repo}
  alias Manifold.Connectors.CalendarMigration
  alias Manifold.Data.CalendarSyncState

  alias Manifold.Data.Schema.{
    CalendarBinding,
    CalendarConnection,
    CalendarEventBinding,
    CalendarSyncResource,
    CalendarSyncAttempt
  }

  defmodule Adapter do
    def fetch_changes(_, _, opts), do: {:ok, Keyword.fetch!(opts, :batch)}

    def decode(snapshot, opts),
      do: {:ok, Map.get(snapshot, :components, Keyword.fetch!(opts, :baseline))}

    def execute(_, _, _) do
      send(self(), :provider_write)
      raise "review must not write"
    end
  end

  setup do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Retained"})

    {:ok, event} =
      Calendars.create_event(calendar.id, %{starts_at: "20261019T100000Z", summary: "Original"})

    connection =
      Repo.insert!(%CalendarConnection{
        provider: "icloud",
        remote_identity: "https://caldav.icloud.com/principal/",
        identity_verified_at: DateTime.utc_now(),
        status: "active"
      })

    binding =
      Repo.insert!(%CalendarBinding{
        calendar_id: calendar.id,
        connection_id: connection.id,
        remote_calendar_id: "https://caldav.icloud.com/calendar/",
        state: "paused",
        legacy_collection_id: Ecto.UUID.generate(),
        enrollment_manifest: %{
          "identity_verification_required" => true,
          "baseline_hydration_required" => true
        }
      })

    resource =
      Repo.insert!(%CalendarSyncResource{
        binding_id: binding.id,
        remote_resource_id: "https://caldav.icloud.com/calendar/event.ics",
        base_raw: "retained old payload",
        etag: "\"old\"",
        status: "uncertain"
      })

    key = event.uid <> <<31>>

    mapping =
      Repo.insert!(%CalendarEventBinding{
        binding_id: binding.id,
        event_id: event.id,
        resource_id: resource.id,
        remote_component_key: key,
        desired_revision: event.local_revision,
        acknowledged_revision: 0
      })

    attempt =
      Repo.insert!(%CalendarSyncAttempt{
        resource_id: resource.id,
        connection_generation: 1,
        binding_generation: 1,
        operation: "upsert",
        destination: resource.remote_resource_id,
        payload: "immutable sent payload",
        precondition: %{"etag" => "\"old\""},
        component_revisions: %{},
        sent_projections: %{},
        state: "uncertain",
        legacy_snapshot: %{"sent_revision" => 9}
      })

    component = %{
      key: key,
      projection: CalendarSyncState.projection(event),
      fields: CalendarSyncState.fields()
    }

    opts = [
      adapter: Adapter,
      baseline: [component],
      batch: %{
        complete: true,
        mode: :full,
        checkpoint: %{},
        resources: [
          %{
            id: resource.remote_resource_id,
            raw: "retained old payload",
            etag: "\"old\"",
            presence: :present,
            components: [component]
          }
        ]
      }
    ]

    %{
      event: event,
      connection: connection,
      binding: binding,
      mapping: mapping,
      attempt: attempt,
      opts: opts
    }
  end

  test "review hydrates semantic baseline without inventing acknowledgments or sending", ctx do
    assert {:ok, review} = CalendarMigration.review(ctx.binding.id, ctx.opts)
    mapping = Repo.get!(CalendarEventBinding, ctx.mapping.id)
    assert mapping.base_projection["summary"] == "Original"
    assert mapping.desired_revision == ctx.event.local_revision
    assert mapping.acknowledged_revision == 0
    attempt = Repo.get!(CalendarSyncAttempt, ctx.attempt.id)
    assert attempt.state == "uncertain"
    assert attempt.payload == "immutable sent payload"
    assert attempt.component_revisions == %{}
    assert attempt.sent_projections == %{}
    refute_received :provider_write
    assert {:ok, activated} = CalendarMigration.activate(ctx.binding.id, review.token, ctx.opts)
    assert activated.state == "active"
    assert activated.calendar_id == ctx.event.calendar_id
    assert Repo.get!(CalendarSyncAttempt, attempt.id).state == "uncertain"

    assert {:error, :stale_preview} =
             CalendarMigration.activate(ctx.binding.id, review.token, ctx.opts)

    refute_received :provider_write
  end

  test "local edits invalidate a persisted migration review", ctx do
    assert {:ok, review} = CalendarMigration.review(ctx.binding.id, ctx.opts)
    assert {:ok, _} = Calendars.update_event(ctx.event.id, %{summary: "New local revision"})

    assert {:error, :stale_preview} =
             CalendarMigration.activate(ctx.binding.id, review.token, ctx.opts)

    assert Repo.get!(CalendarBinding, ctx.binding.id).state == "paused"
    refute_received :provider_write
  end

  test "unverified provider identity cannot be activated", ctx do
    ctx.connection
    |> Ecto.Changeset.change(provider: "google", identity_verified_at: nil, remote_identity: nil)
    |> Repo.update!()

    assert {:error, :identity_verification_required} =
             CalendarMigration.review(ctx.binding.id, ctx.opts)

    assert Repo.get!(CalendarEventBinding, ctx.mapping.id).base_projection == %{}
    assert Repo.get!(CalendarBinding, ctx.binding.id).state == "paused"
    refute_received :provider_write
  end
end
