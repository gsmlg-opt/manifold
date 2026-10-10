defmodule Manifold.Contacts do
  @moduledoc """
  Local-first contacts with durable asynchronous iCloud synchronization intents.
  """

  import Ecto.Query
  alias Manifold.Data.Schema.{Contact, DAVCollection, DAVResource, ICloudConnection}
  alias Manifold.Data.SyncState
  alias Manifold.Repo

  def list_contacts(opts \\ []) do
    limit = bounded_integer(Keyword.get(opts, :limit), 100, 1, 500)
    offset = bounded_integer(Keyword.get(opts, :offset), 0, 0, 1_000_000)

    Contact
    |> visible_contacts(Keyword.get(opts, :include_deleted_conflicts, false))
    |> account_filter(Keyword.get(opts, :account_id))
    |> search(Keyword.get(opts, :search))
    |> order_by([contact], asc: fragment("lower(?)", contact.full_name), asc: contact.id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> preload_sources()
  end

  def get_contact(id, opts \\ []) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Contact{} = contact <- Repo.get(Contact, uuid) do
      contact = preload_sources(contact)

      if is_nil(contact.deleted_at) or
           (Keyword.get(opts, :include_deleted_conflicts, false) and
              match?(%{status: "conflict"}, contact.resource)),
         do: contact
    else
      _ -> nil
    end
  end

  def create_contact(attrs) do
    changeset = Contact.local_changeset(%Contact{}, attrs)

    if changeset.valid? do
      Repo.transaction(fn ->
        lock_target!(Ecto.Changeset.get_field(changeset, :account_id))
        contact = changeset |> Ecto.Changeset.put_change(:local_revision, 1) |> insert!()
        SyncState.stage_contact(contact)
      end)
    else
      {:error, changeset}
    end
  end

  def update_contact(id, attrs) do
    case get_contact(id) do
      nil ->
        {:error, :not_found}

      %Contact{} = contact ->
        changeset = Contact.local_changeset(contact, attrs)

        if changeset.valid? do
          Repo.transaction(fn ->
            account_id = Ecto.Changeset.get_field(changeset, :account_id)
            lock_accounts!([contact.account_id, account_id])

            if (contact.resource_id || contact.collection_id) && account_id != contact.account_id,
              do: Repo.rollback(:local_copy_required)

            lock_target!(account_id, contact.resource_id)
            current = Repo.one(from c in Contact, where: c.id == ^contact.id, lock: "FOR UPDATE")
            if is_nil(current) or current.deleted_at, do: Repo.rollback(:not_found)
            ensure_identity!(current, contact)
            updated = Contact.local_changeset(current, attrs)

            if Enum.any?(updated.changes, fn {field, _} -> field != :sync_to_icloud end),
              do:
                ensure_editable!(
                  current,
                  Ecto.Changeset.get_field(updated, :sync_to_icloud),
                  :update
                )

            updated =
              updated
              |> Ecto.Changeset.put_change(:local_revision, current.local_revision + 1)
              |> update!()

            SyncState.stage_contact(updated)
          end)
        else
          {:error, changeset}
        end
    end
  end

  def delete_contact(id) do
    case get_contact(id) do
      nil ->
        {:error, :not_found}

      %Contact{} = contact ->
        Repo.transaction(fn ->
          lock_target!(contact.account_id, contact.resource_id)
          current = Repo.one(from c in Contact, where: c.id == ^contact.id, lock: "FOR UPDATE")
          if is_nil(current) or current.deleted_at, do: Repo.rollback(:not_found)
          ensure_identity!(current, contact)
          ensure_editable!(current, current.sync_to_icloud, :delete)

          if is_nil(current.resource_id) and is_nil(current.collection_id) do
            Repo.delete!(current)
          else
            deleted =
              current
              |> Ecto.Changeset.change(
                deleted_at: DateTime.utc_now(),
                local_revision: current.local_revision + 1
              )
              |> update!()

            SyncState.stage_contact(deleted, "delete")
          end
        end)
    end
  end

  def change_contact(contact, attrs \\ %{}), do: Contact.local_changeset(contact, attrs)

  def copy_contact(id, attrs \\ %{}) do
    case get_contact(id) do
      nil ->
        {:error, :not_found}

      contact ->
        fields = [
          :full_name,
          :given_name,
          :family_name,
          :organization,
          :notes,
          :emails,
          :phones,
          :addresses
        ]

        create_contact(
          Map.merge(
            Map.take(contact, fields),
            atomize_local_attrs(attrs, fields ++ [:account_id, :sync_to_icloud])
          )
        )
    end
  end

  defp atomize_local_attrs(attrs, fields) do
    Map.new(
      for field <- fields,
          Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)),
          do: {field, Map.get(attrs, field, Map.get(attrs, Atom.to_string(field)))}
    )
  end

  defp lock_target!(account_id, resource_id \\ nil) do
    case SyncState.lock_target("contacts", account_id, resource_id) do
      {:ok, target} -> target
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_editable!(contact, true, operation) when not is_nil(contact.collection_id) do
    collection = Repo.get(DAVCollection, contact.collection_id)
    capability = if operation == :delete, do: :can_delete, else: :can_update

    if collection &&
         (Map.get(collection, capability) == false or
            (Map.get(collection, capability) != true and not collection.writable)),
       do: Repo.rollback(:read_only)
  end

  defp ensure_editable!(_, _, _), do: :ok

  defp lock_accounts!(account_ids) do
    case SyncState.lock_accounts(account_ids) do
      {:ok, accounts} -> accounts
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_identity!(current, observed) do
    fields = [:account_id, :collection_id, :resource_id]
    if Map.take(current, fields) != Map.take(observed, fields), do: Repo.rollback(:stale)
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp visible_contacts(query, false), do: where(query, [contact], is_nil(contact.deleted_at))

  defp visible_contacts(query, true),
    do:
      from(c in query,
        left_join: r in DAVResource,
        on: c.resource_id == r.id,
        where: is_nil(c.deleted_at) or r.status == "conflict"
      )

  defp account_filter(query, nil), do: query

  defp account_filter(query, account_id),
    do: where(query, [contact], contact.account_id == ^account_id)

  defp search(query, value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        query

      term ->
        escaped =
          term
          |> String.replace("\\", "\\\\")
          |> String.replace("%", "\\%")
          |> String.replace("_", "\\_")

        pattern = "%" <> escaped <> "%"

        where(
          query,
          [contact],
          ilike(contact.full_name, ^pattern) or
            ilike(contact.given_name, ^pattern) or
            ilike(contact.family_name, ^pattern) or
            ilike(contact.organization, ^pattern) or
            ilike(fragment("CAST(? AS text)", contact.emails), ^pattern) or
            ilike(fragment("CAST(? AS text)", contact.phones), ^pattern)
        )
    end
  end

  defp search(query, _), do: query

  defp preload_sources(contacts) do
    connection_query =
      from(connection in ICloudConnection,
        select:
          struct(connection, [
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
      )

    Repo.preload(contacts, [:resource, collection: [connection: connection_query]])
  end

  defp bounded_integer(value, _default, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp bounded_integer(_, default, _, _), do: default
end
