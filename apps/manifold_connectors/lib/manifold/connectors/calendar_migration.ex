defmodule Manifold.Connectors.CalendarMigration do
  @moduledoc "Review and activate retained Calendar mappings without issuing provider writes."
  import Ecto.Query
  alias Manifold.Connectors.{CalendarConnections, CalendarSync}

  alias Manifold.Data.Schema.{
    Calendar,
    CalendarBinding,
    CalendarConnection,
    CalendarEvent,
    CalendarEventBinding,
    CalendarSyncResource
  }

  alias Manifold.Repo

  def review(binding_id, opts \\ []) do
    with %CalendarBinding{legacy_collection_id: legacy} = binding when not is_nil(legacy) <-
           Repo.get(CalendarBinding, binding_id),
         {:ok, _} <- verify_connection(binding.connection_id, opts),
         {:ok, _} <- hydrate(binding, opts),
         {:ok, report} <- CalendarSync.compare(binding_id, opts) do
      report = normalize(report)
      token = Ecto.UUID.generate()

      Repo.transaction(fn ->
        current = lock_binding!(binding)
        if current.generation != report["binding_generation"], do: Repo.rollback(:stale)

        manifest =
          Map.put(current.enrollment_manifest, "migration_review", %{
            "token" => token,
            "report" => report
          })

        current |> Ecto.Changeset.change(enrollment_manifest: manifest) |> Repo.update!()
        %{binding_id: binding_id, token: token, report: report}
      end)
    else
      nil -> {:error, :not_found}
      %CalendarBinding{} -> {:error, :not_migrated}
      error -> error
    end
  end

  def activate(binding_id, token, opts \\ []) do
    with %CalendarBinding{} = binding <- Repo.get(CalendarBinding, binding_id),
         true <- binding.state == "paused" and not is_nil(binding.legacy_collection_id),
         %{"token" => ^token, "report" => expected} <-
           binding.enrollment_manifest["migration_review"],
         {:ok, fresh} <- CalendarSync.compare(binding_id, opts),
         true <- normalize(fresh) == expected || {:error, :stale_preview} do
      result =
        Repo.transaction(fn ->
          current = lock_binding!(binding)

          unless current.state == "paused" and current.generation == binding.generation and
                   current.enrollment_manifest["migration_review"]["token"] == token,
                 do: Repo.rollback(:stale_preview)

          connection = Repo.get!(CalendarConnection, current.connection_id)

          if is_nil(connection.identity_verified_at) or
               connection.generation != expected["connection_generation"],
             do: Repo.rollback(:identity_verification_required)

          validate_local_revisions!(expected)

          manifest =
            current.enrollment_manifest
            |> Map.put("confirmed", true)
            |> Map.put("confirmed_at", DateTime.to_iso8601(DateTime.utc_now()))
            |> Map.put("identity_verification_required", false)
            |> Map.put("baseline_hydration_required", false)
            |> Map.put("migration_reviewed_at", DateTime.to_iso8601(DateTime.utc_now()))
            |> Map.delete("migration_review")

          updated =
            current
            |> Ecto.Changeset.change(
              state: "active",
              generation: current.generation + 1,
              enrollment_manifest: manifest
            )
            |> Repo.update!()

          Manifold.Data.CalendarSyncState.enqueue!(updated)
          updated
        end)

      if match?({:ok, _}, result), do: Manifold.Data.CalendarSyncState.notify()
      result
    else
      nil -> {:error, :not_found}
      false -> {:error, :stale_preview}
      {:error, _} = error -> error
      _ -> {:error, :stale_preview}
    end
  end

  defp verify_connection(id, opts) do
    case Repo.get!(CalendarConnection, id) do
      %{identity_verified_at: nil, provider: "icloud"} ->
        CalendarConnections.verify_legacy(id, opts)

      %{identity_verified_at: nil} ->
        {:error, :identity_verification_required}

      connection ->
        {:ok, connection}
    end
  end

  defp hydrate(binding, opts) do
    connection = Repo.get!(CalendarConnection, binding.connection_id)
    adapter = Keyword.get(opts, :adapter, Manifold.Connectors.CalendarSync.ICloud)

    resources =
      Repo.all(from r in CalendarSyncResource, where: r.binding_id == ^binding.id, order_by: r.id)

    decoded =
      Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, acc} ->
        result =
          if resource.base_raw,
            do:
              adapter.decode(
                %{
                  id: resource.remote_resource_id,
                  raw: resource.base_raw,
                  etag: resource.etag,
                  presence: :present
                },
                opts
              ),
            else: {:ok, []}

        case result do
          {:ok, components} -> {:cont, {:ok, [{resource, components} | acc]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, decoded} <- decoded do
      Repo.transaction(fn ->
        current = lock_binding!(binding)

        if current.generation != binding.generation or current.state != "paused",
          do: Repo.rollback(:stale)

        if is_nil(connection.identity_verified_at),
          do: Repo.rollback(:identity_verification_required)

        Enum.each(Enum.reverse(decoded), fn {observed, components} ->
          resource =
            Repo.one!(
              from r in CalendarSyncResource, where: r.id == ^observed.id, lock: "FOR UPDATE"
            )

          if resource.base_raw != observed.base_raw or resource.etag != observed.etag,
            do: Repo.rollback(:stale)

          mappings =
            Repo.all(
              from eb in CalendarEventBinding,
                where: eb.resource_id == ^resource.id,
                order_by: eb.id,
                lock: "FOR UPDATE"
            )

          Enum.each(mappings, fn mapping ->
            baseline = Enum.find(components, &(&1.key == mapping.remote_component_key))

            if baseline do
              # No component ACK is inferred from a legacy resource revision.
              mapping
              |> Ecto.Changeset.change(
                base_projection: baseline.projection,
                projection_fields: baseline.fields
              )
              |> Repo.update!()
            end
          end)
        end)

        manifest =
          current.enrollment_manifest
          |> Map.put("identity_verification_required", false)
          |> Map.put("baseline_hydration_required", false)

        current |> Ecto.Changeset.change(enrollment_manifest: manifest) |> Repo.update!()
      end)
    end
  end

  defp validate_local_revisions!(report) do
    report["resources"]
    |> Enum.flat_map(& &1["components"])
    |> Enum.each(fn component ->
      if event_id = component["event_id"] do
        event = Repo.one(from e in CalendarEvent, where: e.id == ^event_id, lock: "FOR UPDATE")

        if is_nil(event) or event.local_revision != component["local_revision"],
          do: Repo.rollback(:stale_preview)
      end
    end)
  end

  defp lock_binding!(binding) do
    calendar =
      Repo.one(from c in Calendar, where: c.id == ^binding.calendar_id, lock: "FOR UPDATE")

    if is_nil(calendar) or calendar.deleted_at, do: Repo.rollback(:calendar_not_found)
    Repo.one!(from b in CalendarBinding, where: b.id == ^binding.id, lock: "FOR UPDATE")
  end

  defp normalize(value), do: value |> Jason.encode!() |> Jason.decode!()
end
