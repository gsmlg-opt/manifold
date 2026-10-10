defmodule Manifold.Connectors.ICloud.Inbound do
  @moduledoc false
  import Ecto.Query
  alias Manifold.Data.Schema.{DAVResource, Contact, CalendarEvent, Calendar}
  alias Manifold.Repo

  # Called only inside the connection's generation/lease fenced transaction.
  def apply(collection, snapshot, account_id) do
    calendar = if collection.kind == "calendars", do: calendar(collection, account_id)
    Enum.each(snapshot.entries, fn entry -> observe(collection, calendar, entry, account_id) end)

    missing =
      if snapshot.mode == :full do
        seen = Enum.map(snapshot.entries, & &1.href)

        Repo.all(
          from(r in DAVResource,
            where: r.collection_id == ^collection.id and r.href not in ^seen,
            lock: "FOR UPDATE"
          )
        )
      else
        Repo.all(
          from(r in DAVResource,
            where: r.collection_id == ^collection.id and r.href in ^snapshot.deleted,
            lock: "FOR UPDATE"
          )
        )
      end

    Enum.each(missing, &absent(&1, calendar))
  end

  def missing_collection(collection) do
    calendar = Repo.get_by(Calendar, collection_id: collection.id)

    Repo.all(from(r in DAVResource, where: r.collection_id == ^collection.id, lock: "FOR UPDATE"))
    |> Enum.each(&absent(&1, calendar))

    # Retain the collection identity: drafts and suppression mappings depend on it.
    Repo.update!(
      Ecto.Changeset.change(collection,
        writable: false,
        can_create: false,
        can_update: false,
        can_delete: false,
        sync_token: nil
      )
    )
  end

  def project(resource, raw, etag, account_id) do
    parser =
      if resource.kind == "contacts",
        do: Manifold.Connectors.DAV.VCard,
        else: Manifold.Connectors.DAV.ICalendar

    with {:ok, records} <- parser.parse(raw) do
      collection = Repo.get!(Manifold.Data.Schema.DAVCollection, resource.collection_id)
      calendar = if resource.kind == "calendars", do: calendar(collection, account_id)
      project_records(resource, calendar, List.wrap(records), etag, account_id)
      :ok
    end
  end

  defp observe(collection, calendar, entry, account_id) do
    resource =
      Repo.one(
        from(r in DAVResource,
          where: r.collection_id == ^collection.id and r.href == ^entry.href,
          lock: "FOR UPDATE"
        )
      )

    cond do
      is_nil(entry.records) ->
        if is_nil(resource) or resource.etag != entry.etag,
          do: Repo.rollback(:incomplete_response)

      is_nil(resource) ->
        resource =
          Repo.insert!(
            DAVResource.changeset(%DAVResource{}, %{
              kind: collection.kind,
              account_id: account_id,
              connection_id: collection.connection_id,
              collection_id: collection.id,
              href: entry.href,
              uid: hd(entry.records).uid,
              base_raw: hd(entry.records).raw,
              etag: entry.etag,
              status: "synced"
            })
          )

        project_records(resource, calendar, entry.records, entry.etag, account_id)

      resource.sent_revision != nil ->
        persist_resource(resource, %{remote_raw: hd(entry.records).raw, remote_etag: entry.etag})

      not enrolled?(resource, calendar) ->
        persist_resource(resource, %{remote_raw: hd(entry.records).raw, remote_etag: entry.etag})

      resource.status == "conflict" ->
        persist_resource(resource, %{remote_raw: hd(entry.records).raw, remote_etag: entry.etag})

      resource.desired_revision > resource.acknowledged_revision ->
        if entry.etag != resource.etag do
          persist_resource(resource, %{
            status: "conflict",
            remote_raw: hd(entry.records).raw,
            remote_etag: entry.etag,
            last_error: "Both local and iCloud data changed."
          })
        end

      true ->
        project_records(resource, calendar, entry.records, entry.etag, account_id)

        persist_resource(resource, %{
          base_raw: hd(entry.records).raw,
          etag: entry.etag,
          status: "synced",
          remote_raw: nil,
          remote_etag: nil,
          last_error: nil
        })
    end
  end

  defp absent(resource, calendar) do
    cond do
      resource.sent_revision != nil ->
        persist_resource(resource, %{remote_raw: nil, remote_etag: nil})

      not enrolled?(resource, calendar) ->
        :ok

      resource.status == "conflict" ->
        persist_resource(resource, %{remote_raw: nil, remote_etag: nil})

      resource.desired_revision > resource.acknowledged_revision and not is_nil(resource.etag) ->
        if resource.operation == "delete" do
          persist_resource(resource, %{
            acknowledged_revision: resource.desired_revision,
            etag: nil,
            base_raw: nil,
            status: "synced",
            last_error: nil
          })
        else
          persist_resource(resource, %{
            status: "conflict",
            remote_raw: nil,
            remote_etag: nil,
            last_error: "The iCloud resource was deleted while local changes were pending."
          })
        end

      is_nil(resource.etag) ->
        :ok

      true ->
        schema = if resource.kind == "contacts", do: Contact, else: CalendarEvent

        Repo.update_all(from(r in schema, where: r.resource_id == ^resource.id),
          set: [deleted_at: DateTime.utc_now()]
        )

        persist_resource(resource, %{
          etag: nil,
          base_raw: nil,
          status: "synced",
          remote_raw: nil,
          remote_etag: nil
        })
    end
  end

  def enrolled?(%{kind: "contacts"} = resource, _) do
    case Repo.get_by(Contact, resource_id: resource.id) do
      %{sync_to_icloud: true} -> true
      _ -> false
    end
  end

  def enrolled?(%{kind: "calendars"}, %{sync_to_icloud: true}), do: true
  def enrolled?(_, _), do: false

  defp calendar(collection, account_id) do
    Repo.get_by(Calendar, collection_id: collection.id) ||
      Repo.insert!(
        Calendar.changeset(%Calendar{}, %{
          name: collection.name,
          account_id: account_id,
          collection_id: collection.id
        })
      )
  end

  defp project_records(resource, calendar, records, etag, account_id) do
    schema = if resource.kind == "contacts", do: Contact, else: CalendarEvent

    Enum.each(records, fn attrs ->
      existing =
        if resource.kind == "contacts" do
          Repo.get_by(Contact, resource_id: resource.id) ||
            Repo.get_by(Contact,
              collection_id: resource.collection_id,
              resource_href: resource.href
            )
        else
          Repo.get_by(CalendarEvent,
            resource_id: resource.id,
            uid: attrs.uid,
            recurrence_id: attrs.recurrence_id
          ) ||
            Repo.get_by(CalendarEvent,
              collection_id: resource.collection_id,
              resource_href: resource.href,
              uid: attrs.uid,
              recurrence_id: attrs.recurrence_id
            )
        end

      attrs =
        Map.merge(attrs, %{
          collection_id: resource.collection_id,
          resource_href: resource.href,
          etag: etag,
          resource_id: resource.id,
          deleted_at: nil
        })

      attrs =
        if schema == Contact,
          do: Map.put(attrs, :account_id, account_id),
          else: Map.put(attrs, :calendar_id, calendar.id)

      changeset = schema.changeset(existing || struct(schema), attrs)
      if existing, do: Repo.update!(changeset), else: Repo.insert!(changeset)
    end)

    if schema == CalendarEvent do
      identities = MapSet.new(Enum.map(records, &{&1.uid, &1.recurrence_id}))

      Repo.all(from(e in CalendarEvent, where: e.resource_id == ^resource.id))
      |> Enum.reject(&MapSet.member?(identities, {&1.uid, &1.recurrence_id}))
      |> Enum.each(&Repo.update!(Ecto.Changeset.change(&1, deleted_at: DateTime.utc_now())))
    end
  end

  defp persist_resource(resource, attrs), do: Repo.update!(DAVResource.changeset(resource, attrs))
end
