defmodule Manifold.Connectors.CalendarSync.CoordinatorTest do
  use Manifold.DataCase, async: true
  alias Manifold.Connectors.CalendarSync
  alias Manifold.Data.CalendarSyncState

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

  defmodule Adapter do
    def fetch_changes(_, _, opts),
      do:
        {:ok,
         Keyword.get(opts, :batch, %{complete: true, mode: :delta, checkpoint: %{}, resources: []})}

    def decode(snapshot, _), do: {:ok, Map.get(snapshot, :components, [])}

    def encode(_, components, opts) do
      if opts[:on_encode], do: opts[:on_encode].()
      {:ok, Jason.encode!(Enum.map(components, &Map.take(&1, [:key, :projection])))}
    end

    def execute(attempt, _, opts) do
      send(self(), {:execute, attempt})
      if opts[:on_execute], do: opts[:on_execute].()
      Keyword.get(opts, :result, {:ok, %{etag: "\"written\""}})
    end

    def fetch_resource(_, opts), do: Keyword.fetch!(opts, :reconciled)
  end

  setup do
    c = Repo.insert!(Ecto.Changeset.change(%Calendar{}, name: "Local"))
    g = connection("google")
    a = connection("icloud")
    gb = binding(c, g)
    ab = binding(c, a)
    %{calendar: c, google: gb, apple: ab}
  end

  test "targets acknowledge independently and a late acknowledgment cannot revive a tombstone",
       ctx do
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    assert Repo.aggregate(CalendarEventBinding, :count) == 2

    {:ok, _} =
      CalendarSync.run(ctx.google.id, ctx.google.generation,
        adapter: Adapter,
        on_execute: fn ->
          Repo.transaction(fn ->
            e =
              Repo.get!(CalendarEvent, e.id)
              |> Ecto.Changeset.change(local_revision: 2, deleted_at: DateTime.utc_now())
              |> Repo.update!()

            CalendarSyncState.stage_events!(ctx.calendar, [e])
          end)
        end
      )

    ge = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id)
    ae = Repo.get_by!(CalendarEventBinding, binding_id: ctx.apple.id, event_id: e.id)
    assert ge.acknowledged_revision == 1
    assert ge.desired_revision == 2
    assert ae.acknowledged_revision == 0
    assert ae.desired_revision == 2
    assert Repo.get!(CalendarEvent, e.id).deleted_at
  end

  test "accepted remote edits fan out while echoes do not add canonical revisions", ctx do
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    {:ok, _} = CalendarSync.run(ctx.google.id, 1, adapter: Adapter)
    eb = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id)
    r = Repo.get!(CalendarSyncResource, eb.resource_id)
    projection = CalendarSyncState.projection(e) |> Map.put("summary", "From Google")

    snapshot = %{
      id: r.remote_resource_id,
      href: r.href,
      raw: "remote",
      etag: "\"next\"",
      presence: :present,
      components: [
        %{
          key: eb.remote_component_key,
          projection: projection,
          fields: Map.keys(projection),
          metadata: %{}
        }
      ]
    }

    batch = %{
      complete: true,
      mode: :delta,
      checkpoint: %{"token" => "new"},
      resources: [snapshot]
    }

    assert {:ok, _} = CalendarSync.apply_batch(ctx.google.id, batch, adapter: Adapter)
    changed = Repo.get!(CalendarEvent, e.id)
    assert changed.summary == "From Google"
    assert changed.local_revision == 2

    assert Repo.get_by!(CalendarEventBinding, binding_id: ctx.apple.id, event_id: e.id).desired_revision ==
             2

    assert {:ok, _} = CalendarSync.apply_batch(ctx.google.id, batch, adapter: Adapter)
    assert Repo.get!(CalendarEvent, e.id).local_revision == 2
  end

  test "incomplete batches and missing containers do not delete local events", ctx do
    e = event(ctx.calendar)

    assert {:error, :incomplete_batch} =
             CalendarSync.apply_batch(ctx.google.id, %{complete: false, resources: []},
               adapter: Adapter
             )

    assert {:ok, _} = CalendarSync.mark_unavailable(ctx.google.id, :not_found)
    assert is_nil(Repo.get!(CalendarEvent, e.id).deleted_at)
  end

  test "paused targets accumulate intent and detached ones retain archived evidence", ctx do
    {:ok, paused} = CalendarSync.pause(ctx.google.id)
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)

    assert {:error, :disabled} =
             CalendarSync.run(ctx.google.id, paused.generation, adapter: Adapter)

    assert Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id).desired_revision ==
             1

    {:ok, _} = CalendarSync.detach(ctx.google.id)
    e = Repo.update!(Ecto.Changeset.change(e, local_revision: 2))
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)

    assert Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id).desired_revision ==
             1

    assert Repo.get!(CalendarBinding, ctx.google.id).suppressed_at
  end

  test "unknown writes reconcile their immutable payload before another dispatch", ctx do
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    {:ok, _} = CalendarSync.run(ctx.google.id, 1, adapter: Adapter, result: {:error, :unknown})
    assert_receive {:execute, sent}
    assert Repo.get!(CalendarSyncAttempt, sent.id).state == "uncertain"
    eb = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id)
    r = Repo.get!(CalendarSyncResource, eb.resource_id)

    snapshot = %{
      id: r.remote_resource_id,
      raw: sent.payload,
      etag: "\"found\"",
      presence: :present,
      components: [
        %{
          key: eb.remote_component_key,
          projection: CalendarSyncState.projection(e),
          fields: Map.keys(CalendarSyncState.projection(e)),
          metadata: %{}
        }
      ]
    }

    assert {:ok, _} =
             CalendarSync.run(ctx.google.id, 1, adapter: Adapter, reconciled: {:ok, snapshot})

    refute_receive {:execute, _}
    assert Repo.get!(CalendarSyncAttempt, sent.id).state == "succeeded"

    assert Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id).acknowledged_revision ==
             1
  end

  test "concurrent remote edit is isolated as conflict and cannot propagate", ctx do
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    {:ok, _} = CalendarSync.run(ctx.google.id, 1, adapter: Adapter)
    e = Repo.update!(Ecto.Changeset.change(e, summary: "Local", local_revision: 2))
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    eb = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id)
    r = Repo.get!(CalendarSyncResource, eb.resource_id)
    p = CalendarSyncState.projection(e) |> Map.put("summary", "Remote")

    batch = %{
      complete: true,
      mode: :delta,
      checkpoint: %{},
      resources: [
        %{
          id: r.remote_resource_id,
          raw: "candidate",
          etag: "\"other\"",
          presence: :present,
          components: [%{key: eb.remote_component_key, projection: p, fields: Map.keys(p)}]
        }
      ]
    }

    assert {:ok, _} = CalendarSync.apply_batch(ctx.google.id, batch, adapter: Adapter)
    assert Repo.get!(CalendarEvent, e.id).summary == "Local"
    assert Repo.get_by!(CalendarEventBinding, id: eb.id).conflict["remote"]["summary"] == "Remote"
    assert {:ok, preview} = CalendarSync.conflict_preview(eb.id)

    assert {:error, :stale_preview} =
             CalendarSync.resolve_conflict(
               eb.id,
               Map.put(preview.version, "local_revision", 0),
               :remote
             )

    assert {:ok, _} = CalendarSync.resolve_conflict(eb.id, preview.version, :remote)
    assert Repo.get!(CalendarEvent, e.id).summary == "Remote"

    assert Repo.get_by!(CalendarEventBinding, binding_id: ctx.apple.id, event_id: e.id).desired_revision ==
             3
  end

  test "historical enrollment requires a current persisted preview and explicit selections",
       ctx do
    historical = event(ctx.calendar)
    connection = connection("google")
    remote = %{id: "second", name: "Second", capabilities: %{"write" => true}}

    assert {:ok, preview} =
             CalendarSync.preview(ctx.calendar.id, connection.id, remote, adapter: Adapter)

    assert Repo.get_by(CalendarEventBinding, binding_id: preview.id, event_id: historical.id) ==
             nil

    token = preview.enrollment_manifest["token"]

    assert {:error, :stale_preview} =
             CalendarSync.confirm(preview.id, "wrong", %{upload_event_ids: [historical.id]},
               adapter: Adapter
             )

    assert {:ok, confirmed} =
             CalendarSync.confirm(preview.id, token, %{upload_event_ids: [historical.id]},
               adapter: Adapter
             )

    assert confirmed.enrollment_manifest["selection"]["upload_event_ids"] == [historical.id]

    assert Repo.get_by!(CalendarEventBinding, binding_id: preview.id, event_id: historical.id).desired_revision ==
             1
  end

  test "a changed remote preview cannot activate historical uploads", ctx do
    connection = connection("google")
    remote = %{id: "second", name: "Second", capabilities: %{}}

    {:ok, preview} =
      CalendarSync.preview(ctx.calendar.id, connection.id, remote, adapter: Adapter)

    batch = %{
      complete: true,
      mode: :full,
      checkpoint: %{},
      resources: [
        %{id: "new", etag: "changed", raw: "remote", presence: :present, components: []}
      ]
    }

    assert {:error, :stale_preview} =
             CalendarSync.confirm(preview.id, preview.enrollment_manifest["token"], %{},
               adapter: Adapter,
               batch: batch
             )

    assert Repo.get!(CalendarBinding, preview.id).state == "preview"
  end

  test "reliable remote event deletion propagates", ctx do
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    {:ok, _} = CalendarSync.run(ctx.google.id, 1, adapter: Adapter)
    eb = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id)
    r = Repo.get!(CalendarSyncResource, eb.resource_id)

    batch = %{
      complete: true,
      mode: :delta,
      checkpoint: %{},
      resources: [%{id: r.remote_resource_id, presence: :deleted, raw: nil, etag: nil}]
    }

    assert {:ok, _} = CalendarSync.apply_batch(ctx.google.id, batch, adapter: Adapter)
    deleted = Repo.get!(CalendarEvent, e.id)
    assert deleted.deleted_at
    assert deleted.local_revision == 2

    assert Repo.get_by!(CalendarEventBinding, binding_id: ctx.apple.id, event_id: e.id).desired_revision ==
             2
  end

  test "Google components have independent resources while iCloud series share a vector", ctx do
    master = event(ctx.calendar)

    exception =
      Repo.insert!(
        Ecto.Changeset.change(%CalendarEvent{},
          calendar_id: ctx.calendar.id,
          uid: master.uid,
          series_id: master.series_id,
          recurrence_id: "20261020T100000Z",
          starts_at: "20261020T120000Z",
          local_revision: 1
        )
      )

    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [master, exception]) end)
    gm = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: master.id)
    ge = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: exception.id)
    am = Repo.get_by!(CalendarEventBinding, binding_id: ctx.apple.id, event_id: master.id)
    ae = Repo.get_by!(CalendarEventBinding, binding_id: ctx.apple.id, event_id: exception.id)
    refute gm.resource_id == ge.resource_id
    assert am.resource_id == ae.resource_id
    assert {:ok, _} = CalendarSync.run(ctx.apple.id, 1, adapter: Adapter)
    assert_receive {:execute, attempt}
    assert attempt.component_revisions == %{master.id => 1, exception.id => 1}
  end

  test "legacy identity review gate prevents network admission", ctx do
    Repo.update!(
      Ecto.Changeset.change(ctx.google,
        enrollment_manifest: %{"identity_verification_required" => true}
      )
    )

    assert {:error, :migration_review_required} =
             CalendarSync.run(ctx.google.id, 1, adapter: Adapter)

    refute_receive {:execute, _}
  end

  test "an unknown differing outcome is a candidate and never propagates", ctx do
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    {:ok, _} = CalendarSync.run(ctx.google.id, 1, adapter: Adapter, result: {:error, :unknown})
    assert_receive {:execute, _}
    eb = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id)
    r = Repo.get!(CalendarSyncResource, eb.resource_id)
    remote = CalendarSyncState.projection(e) |> Map.put("summary", "Unproven remote")

    snapshot = %{
      id: r.remote_resource_id,
      raw: "different",
      etag: "other",
      presence: :present,
      components: [%{key: eb.remote_component_key, projection: remote, fields: Map.keys(remote)}]
    }

    assert {:ok, _} =
             CalendarSync.run(ctx.google.id, 1, adapter: Adapter, reconciled: {:ok, snapshot})

    assert Repo.get!(CalendarEvent, e.id).summary == "Original"
    assert Repo.get!(CalendarEvent, e.id).local_revision == 1

    assert Repo.get!(CalendarEventBinding, eb.id).conflict["remote"]["summary"] ==
             "Unproven remote"

    refute_receive {:execute, _}
  end

  test "target capabilities prevent dispatch without rejecting canonical edits", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.google, capabilities: %{"create" => false}))
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    assert {:ok, _} = CalendarSync.run(ctx.google.id, 1, adapter: Adapter)
    refute_receive {:execute, _}
    eb = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id)
    assert Repo.get!(CalendarSyncResource, eb.resource_id).status == "limited"
    assert Repo.get!(CalendarEvent, e.id).summary == "Original"
  end

  test "old local tombstones do not invalidate an enrollment preview", ctx do
    e = event(ctx.calendar)
    Repo.update!(Ecto.Changeset.change(e, deleted_at: DateTime.utc_now()))
    connection = connection("google")

    {:ok, preview} =
      CalendarSync.preview(
        ctx.calendar.id,
        connection.id,
        %{id: "new-target", name: "Fresh", capabilities: %{}},
        adapter: Adapter
      )

    assert {:ok, _} =
             CalendarSync.confirm(preview.id, preview.enrollment_manifest["token"], %{},
               adapter: Adapter
             )

    assert is_nil(Repo.get_by(CalendarEventBinding, binding_id: preview.id, event_id: e.id))
  end

  test "inherited reminders remain limited even when canonical reminders are empty", ctx do
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    {:ok, _} = CalendarSync.run(ctx.google.id, 1, adapter: Adapter)
    assert_receive {:execute, _}
    eb = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id)
    r = Repo.get!(CalendarSyncResource, eb.resource_id)
    p = CalendarSyncState.projection(e) |> Map.delete("reminders")

    snapshot = %{
      id: r.remote_resource_id,
      raw: "inherited",
      etag: "default-reminders",
      presence: :present,
      components: [
        %{
          key: eb.remote_component_key,
          projection: p,
          fields: Map.keys(p),
          metadata: %{capability_limits: ["inherited_default_reminders"]}
        }
      ]
    }

    assert {:ok, _} =
             CalendarSync.apply_batch(
               ctx.google.id,
               %{complete: true, mode: :delta, checkpoint: %{}, resources: [snapshot]},
               adapter: Adapter
             )

    assert Repo.get!(CalendarEvent, e.id).reminders == []
    assert Repo.get!(CalendarEventBinding, eb.id).state == "limited"
    assert Repo.get!(CalendarEventBinding, eb.id).last_error =~ "inherited_default_reminders"
    assert Repo.get!(CalendarSyncResource, r.id).status == "limited"
    assert {:ok, _} = CalendarSync.run(ctx.google.id, 1, adapter: Adapter)
    refute_receive {:execute, _}
  end

  test "a sparse remote cancellation conflicts with an unacknowledged local edit", ctx do
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    {:ok, _} = CalendarSync.run(ctx.google.id, 1, adapter: Adapter)
    edited = Repo.update!(Ecto.Changeset.change(e, summary: "Local draft", local_revision: 2))
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [edited]) end)
    eb = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id)
    r = Repo.get!(CalendarSyncResource, eb.resource_id)

    snapshot = %{
      id: r.remote_resource_id,
      raw: "cancelled",
      etag: "cancel-version",
      presence: :present,
      components: [
        %{
          key: eb.remote_component_key,
          projection: %{"deleted" => true, "recurrence_id" => ""},
          fields: ["deleted", "recurrence_id"]
        }
      ]
    }

    assert {:ok, _} =
             CalendarSync.apply_batch(
               ctx.google.id,
               %{complete: true, mode: :delta, checkpoint: %{}, resources: [snapshot]},
               adapter: Adapter
             )

    assert is_nil(Repo.get!(CalendarEvent, e.id).deleted_at)
    assert Repo.get!(CalendarEvent, e.id).summary == "Local draft"
    assert Repo.get!(CalendarEventBinding, eb.id).conflict["remote"]["deleted"]
  end

  test "explicit re-enrollment preserves identities and unknown attempts but excludes unselected history",
       ctx do
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    {:ok, _} = CalendarSync.run(ctx.google.id, 1, adapter: Adapter, result: {:error, :unknown})
    assert_receive {:execute, sent}
    {:ok, _} = CalendarSync.detach(ctx.google.id)

    edited =
      Repo.update!(Ecto.Changeset.change(e, summary: "Edited while detached", local_revision: 2))

    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [edited]) end)
    {:ok, preview} = CalendarSync.reenroll_preview(ctx.google.id, adapter: Adapter)
    assert preview.id == ctx.google.id
    assert Repo.get!(CalendarSyncAttempt, sent.id).state == "uncertain"
    assert preview.enrollment_manifest["prior_enrollments"] != []

    {:ok, confirmed} =
      CalendarSync.confirm(preview.id, preview.enrollment_manifest["token"], %{},
        adapter: Adapter
      )

    assert is_nil(confirmed.suppressed_at)
    eb = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id)
    assert eb.state == "suppressed"
    assert eb.desired_revision == 1
    r = Repo.get!(CalendarSyncResource, eb.resource_id)
    p = CalendarSyncState.projection(e)

    snapshot = %{
      id: r.remote_resource_id,
      raw: sent.payload,
      etag: "confirmed-old",
      presence: :present,
      components: [%{key: eb.remote_component_key, projection: p, fields: Map.keys(p)}]
    }

    assert {:ok, _} =
             CalendarSync.run(confirmed.id, confirmed.generation,
               adapter: Adapter,
               reconciled: {:ok, snapshot}
             )

    refute_receive {:execute, _}
    assert Repo.get!(CalendarSyncAttempt, sent.id).state == "succeeded"
    assert Repo.get!(CalendarEvent, e.id).summary == "Edited while detached"
    assert Repo.get!(CalendarEventBinding, eb.id).state == "suppressed"
  end

  for {change, label} <- [{[status: "paused"], "pause"}, {[generation: 2], "generation change"}] do
    test "a connection #{label} before dispatch admission keeps the prepared request without sending",
         ctx do
      e = event(ctx.calendar)
      Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
      connection = Repo.get!(CalendarConnection, ctx.google.connection_id)

      assert {:error, :stale} =
               CalendarSync.run(ctx.google.id, 1,
                 adapter: Adapter,
                 on_encode: fn ->
                   Repo.update!(Ecto.Changeset.change(connection, unquote(change)))
                 end
               )

      refute_receive {:execute, _}
      assert [attempt] = Repo.all(CalendarSyncAttempt)
      assert attempt.state == "prepared"
      assert is_nil(attempt.dispatched_at)
      assert attempt.component_revisions == %{e.id => 1}
      assert Repo.get!(CalendarEvent, e.id).summary == "Original"

      assert Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id).acknowledged_revision ==
               0

      assert is_nil(Repo.get!(CalendarBinding, ctx.google.id).lease_owner)
    end
  end

  test "legacy readback establishes a baseline without inventing a current event ACK", ctx do
    e = event(ctx.calendar)
    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [e]) end)
    eb = Repo.get_by!(CalendarEventBinding, binding_id: ctx.google.id, event_id: e.id)
    r = Repo.get!(CalendarSyncResource, eb.resource_id)
    p = CalendarSyncState.projection(e)

    sent =
      Repo.insert!(
        Ecto.Changeset.change(%CalendarSyncAttempt{},
          resource_id: r.id,
          connection_generation: 1,
          binding_generation: 1,
          operation: "upsert",
          destination: r.remote_resource_id,
          payload: "legacy accepted payload",
          state: "uncertain",
          component_revisions: %{},
          sent_projections: %{}
        )
      )

    Repo.update!(Ecto.Changeset.change(r, base_raw: "prior baseline", remote_presence: "present"))
    Repo.update!(Ecto.Changeset.change(eb, base_projection: p, projection_fields: Map.keys(p)))

    edited =
      Repo.update!(Ecto.Changeset.change(e, summary: "Newer local edit", local_revision: 2))

    Repo.transaction(fn -> CalendarSyncState.stage_events!(ctx.calendar, [edited]) end)

    snapshot = %{
      id: r.remote_resource_id,
      raw: sent.payload,
      etag: "legacy-accepted",
      presence: :present,
      components: [%{key: eb.remote_component_key, projection: p, fields: Map.keys(p)}]
    }

    {:ok, _} =
      CalendarSync.run(ctx.google.id, 1,
        adapter: Adapter,
        reconciled: {:ok, snapshot},
        result: {:error, :unknown}
      )

    assert Repo.get!(CalendarSyncAttempt, sent.id).state == "succeeded"
    assert_receive {:execute, current}
    assert current.component_revisions == %{e.id => 2}
    assert Repo.get!(CalendarEventBinding, eb.id).acknowledged_revision == 0
    assert Repo.get!(CalendarEventBinding, eb.id).base_projection == p
    assert Repo.get!(CalendarEvent, e.id).summary == "Newer local edit"
  end

  defp connection(provider),
    do:
      Repo.insert!(
        Ecto.Changeset.change(%CalendarConnection{},
          provider: provider,
          status: "active",
          generation: 1,
          credential_context: "test",
          encrypted_credentials: "test"
        )
      )

  defp binding(c, connection),
    do:
      Repo.insert!(
        Ecto.Changeset.change(%CalendarBinding{},
          calendar_id: c.id,
          connection_id: connection.id,
          remote_calendar_id: Ecto.UUID.generate(),
          state: "active",
          direction: "bidirectional",
          capabilities: %{"write" => true},
          enrollment_manifest: %{"confirmed_at" => "2000-01-01T00:00:00Z"}
        )
      )

  defp event(c),
    do:
      Repo.insert!(
        Ecto.Changeset.change(%CalendarEvent{},
          calendar_id: c.id,
          uid: Ecto.UUID.generate(),
          series_id: Ecto.UUID.generate(),
          starts_at: "20261019T100000Z",
          summary: "Original",
          local_revision: 1
        )
      )
end
