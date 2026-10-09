defmodule Manifold.Connectors.ICloud.Sync do
  @moduledoc false
  import Ecto.Query
  alias Manifold.Connectors.{Crypto, ICloud}
  alias Manifold.Connectors.DAV.{Client, URL, VCard, ICalendar}
  alias Manifold.Data.Schema.{ICloudConnection, DAVCollection, Contact, CalendarEvent}
  alias Manifold.Repo

  def run(id, generation, opts \\ []) do
    with {:ok, connection} <- acquire(id, generation) do
      try do
        case Crypto.decrypt(
               connection.password_ciphertext,
               "icloud:#{connection.id}:app_password"
             ) do
          {:ok, password} ->
            credentials = %{apple_id: connection.apple_id, app_password: password}

            results =
              Enum.map(selected(connection), fn kind ->
                case fetch_service(connection, kind, credentials, opts) do
                  {:ok, snapshots} ->
                    case commit_service(connection, kind, snapshots) do
                      :ok -> :ok
                      {:error, :stale} = error -> error
                      {:error, reason} -> fail_service(connection, kind, reason)
                    end

                  {:error, reason} ->
                    fail_service(connection, kind, reason)
                end
              end)

            aggregate(results)

          _ ->
            Enum.each(
              selected(connection),
              &fail_service(connection, &1, :credential_unavailable)
            )

            {:error, :reconnect_required}
        end
      rescue
        _ ->
          Enum.each(selected(connection), &fail_service(connection, &1, :sync_failed))
          {:error, :sync_failed}
      after
        release(connection)
      end
    end
  end

  defp aggregate(results) do
    rates = for {:error, {:rate_limited, seconds}} <- results, do: seconds

    cond do
      Enum.member?(results, {:error, :stale}) -> {:error, :stale}
      rates != [] -> {:error, {:rate_limited, Enum.max(rates)}}
      true -> Enum.find(results, &match?({:error, _}, &1)) || :ok
    end
  end

  defp acquire(id, generation) do
    Repo.transaction(fn ->
      c = ICloud.locked!(id)
      now = DateTime.utc_now()

      cond do
        c.generation != generation ->
          Repo.rollback(:stale)

        not c.enabled ->
          Repo.rollback(:disabled)

        ICloud.cooldown_seconds(c) > 0 ->
          Repo.rollback({:rate_limited, ICloud.cooldown_seconds(c)})

        c.sync_owner && c.sync_expires_at && DateTime.compare(c.sync_expires_at, now) == :gt ->
          Repo.rollback(:busy)

        selected(c) == [] ->
          Repo.rollback(:reconnect_required)

        true ->
          statuses =
            Enum.reduce(selected(c), %{}, fn kind, acc ->
              Map.put(acc, fields(kind).status, "syncing")
            end)

          ICloud.update!(
            c,
            Map.merge(statuses, %{
              sync_owner: Ecto.UUID.generate(),
              sync_expires_at: DateTime.add(now, 600)
            })
          )
      end
    end)
  end

  defp selected(c) do
    Enum.filter(["contacts", "calendars"], fn kind ->
      f = fields(kind)
      Map.fetch!(c, f.enabled) and Map.fetch!(c, f.status) != "reconnect_required"
    end)
  end

  defp fetch_service(c, kind, credentials, opts) do
    client = Keyword.get(opts, :client, Client)

    with {:ok, collections} <- client.discover(credentials, kind, opts),
         true <-
           is_list(collections) and length(collections) <= 100 and
             unique?(Enum.map(collections, & &1.href)) do
      Enum.reduce_while(collections, {:ok, []}, fn remote, {:ok, acc} ->
        existing = Repo.get_by(DAVCollection, connection_id: c.id, kind: kind, href: remote.href)

        collection =
          existing ||
            %DAVCollection{connection_id: c.id, kind: kind, href: remote.href, name: remote.name}

        etags = existing_etags(collection)

        with {:ok, _} <- URL.validate(remote.href),
             {:ok, snapshot} <-
               client.sync_collection(
                 collection,
                 credentials,
                 Keyword.put(opts, :existing_etags, etags)
               ),
             {:ok, prepared} <- prepare(collection, snapshot) do
          {:cont, {:ok, [%{collection: collection, name: remote.name, snapshot: prepared} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
          _ -> {:halt, {:error, :incomplete_response}}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :incomplete_response}
    end
  end

  defp existing_etags(%{id: nil}), do: %{}

  defp existing_etags(c) do
    schema = schema(c.kind)

    Repo.all(from r in schema, where: r.collection_id == ^c.id, select: {r.resource_href, r.etag})
    |> Map.new()
  end

  defp prepare(c, %{mode: mode, entries: entries, deleted: deleted, sync_token: token})
       when mode in [:full, :delta] and is_list(entries) and is_list(deleted) do
    hrefs = Enum.map(entries, & &1.href)

    valid =
      length(entries) <= 5000 and length(deleted) <= 5000 and unique?(hrefs) and unique?(deleted) and
        Enum.all?(hrefs ++ deleted, &resource_url?(c.href, &1)) and
        MapSet.disjoint?(MapSet.new(hrefs), MapSet.new(deleted))

    if valid do
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        case entry.content do
          nil ->
            {:cont, {:ok, [Map.put(entry, :records, nil) | acc]}}

          raw ->
            parser = if c.kind == "contacts", do: VCard, else: ICalendar

            case parser.parse(raw) do
              {:ok, records} ->
                {:cont, {:ok, [Map.put(entry, :records, List.wrap(records)) | acc]}}

              _ ->
                {:halt, {:error, :invalid_resource}}
            end
        end
      end)
      |> case do
        {:ok, prepared} ->
          {:ok,
           %{mode: mode, entries: Enum.reverse(prepared), deleted: deleted, sync_token: token}}

        error ->
          error
      end
    else
      {:error, :incomplete_response}
    end
  end

  defp prepare(_, _), do: {:error, :incomplete_response}

  defp resource_url?(base, href) do
    case URL.validate(href) do
      {:ok, canonical} ->
        canonical == href and String.starts_with?(href, String.trim_trailing(base, "/") <> "/")

      _ ->
        false
    end
  end

  defp unique?(values), do: length(values) == MapSet.size(MapSet.new(values))

  defp commit_service(c, kind, snapshots) do
    result =
      Repo.transaction(fn ->
        locked = current!(c)

        Enum.each(snapshots, fn data ->
          collection =
            data.collection
            |> DAVCollection.changeset(%{name: data.name, sync_token: data.snapshot.sync_token})
            |> persist!()

          apply_snapshot(collection, data.snapshot)
        end)

        hrefs = Enum.map(snapshots, & &1.collection.href)

        Repo.delete_all(
          from collection in DAVCollection,
            where:
              collection.connection_id == ^c.id and collection.kind == ^kind and
                collection.href not in ^hrefs
        )

        f = fields(kind)

        ICloud.update!(locked, %{
          f.status => "connected",
          f.error => nil,
          f.synced => DateTime.utc_now()
        })
      end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_snapshot(c, snapshot) do
    schema = schema(c.kind)

    Enum.each(snapshot.entries, fn entry ->
      if is_nil(entry.records) do
        rows =
          Repo.all(
            from r in schema, where: r.collection_id == ^c.id and r.resource_href == ^entry.href
          )

        if rows == [] or Enum.any?(rows, &(&1.etag != entry.etag)),
          do: Repo.rollback(:incomplete_response)
      else
        Enum.each(entry.records, fn attrs ->
          attrs =
            Map.merge(attrs, %{collection_id: c.id, resource_href: entry.href, etag: entry.etag})

          existing =
            if c.kind == "contacts" do
              Repo.get_by(Contact, collection_id: c.id, resource_href: entry.href)
            else
              Repo.get_by(CalendarEvent,
                collection_id: c.id,
                resource_href: entry.href,
                uid: attrs.uid,
                recurrence_id: attrs.recurrence_id
              )
            end

          (existing || struct(schema)) |> schema.changeset(attrs) |> persist!()
        end)

        if c.kind == "calendars" do
          identities = MapSet.new(Enum.map(entry.records, &{&1.uid, &1.recurrence_id}))

          Repo.all(
            from r in CalendarEvent,
              where: r.collection_id == ^c.id and r.resource_href == ^entry.href
          )
          |> Enum.reject(&MapSet.member?(identities, {&1.uid, &1.recurrence_id}))
          |> Enum.each(&Repo.delete!/1)
        end
      end
    end)

    if snapshot.mode == :full do
      seen = Enum.map(snapshot.entries, & &1.href)

      Repo.delete_all(
        from r in schema, where: r.collection_id == ^c.id and r.resource_href not in ^seen
      )
    else
      Repo.delete_all(
        from r in schema, where: r.collection_id == ^c.id and r.resource_href in ^snapshot.deleted
      )
    end
  end

  defp fail_service(c, kind, reason) do
    {status, message, delay} = failure(reason)

    result =
      Repo.transaction(fn ->
        locked = current!(c)
        f = fields(kind)
        retry_at = DateTime.add(DateTime.utc_now(), delay)

        next =
          if locked.next_sync_at && DateTime.compare(locked.next_sync_at, retry_at) == :gt,
            do: locked.next_sync_at,
            else: retry_at

        ICloud.update!(locked, %{f.status => status, f.error => message, :next_sync_at => next})
      end)

    case result do
      {:ok, _} -> {:error, reason}
      {:error, _} -> {:error, :stale}
    end
  end

  defp current!(expected) do
    c =
      case Repo.get(ICloudConnection, expected.id) do
        nil -> Repo.rollback(:stale)
        _ -> ICloud.locked!(expected.id)
      end

    if (c.enabled and c.generation == expected.generation and c.sync_owner == expected.sync_owner and
          c.sync_expires_at) && DateTime.compare(c.sync_expires_at, DateTime.utc_now()) == :gt,
       do: c,
       else: Repo.rollback(:stale)
  end

  defp release(expected) do
    Repo.transaction(fn ->
      case Repo.get(ICloudConnection, expected.id) do
        nil ->
          :ok

        _ ->
          c = ICloud.locked!(expected.id)

          if c.generation == expected.generation and c.sync_owner == expected.sync_owner do
            next = DateTime.add(DateTime.utc_now(), 300)

            next =
              if c.next_sync_at && DateTime.compare(c.next_sync_at, next) == :gt,
                do: c.next_sync_at,
                else: next

            ICloud.update!(c, %{sync_owner: nil, sync_expires_at: nil, next_sync_at: next})
          end
      end
    end)
  end

  defp persist!(changeset) do
    result =
      if Ecto.get_meta(changeset.data, :state) == :loaded,
        do: Repo.update(changeset),
        else: Repo.insert(changeset)

    case result do
      {:ok, record} -> record
      _ -> Repo.rollback(:invalid_resource)
    end
  end

  defp schema("contacts"), do: Contact
  defp schema("calendars"), do: CalendarEvent

  defp fields("contacts"),
    do: %{
      enabled: :contacts_enabled,
      status: :contacts_status,
      error: :contacts_error,
      synced: :contacts_synced_at
    }

  defp fields("calendars"),
    do: %{
      enabled: :calendars_enabled,
      status: :calendars_status,
      error: :calendars_error,
      synced: :calendars_synced_at
    }

  defp failure(:credential_unavailable),
    do: {"reconnect_required", "Saved credentials cannot be decrypted. Reconnect iCloud.", 300}

  defp failure(:unauthorized),
    do:
      {"reconnect_required", "iCloud authorization failed. Replace the app-specific password.",
       300}

  defp failure({:rate_limited, seconds}) when is_integer(seconds),
    do: {"failed", "Rate limited; synchronization will retry.", max(1, min(seconds, 86_400))}

  defp failure(_), do: {"failed", "Synchronization failed; previous data was retained.", 300}
end
