defmodule Manifold.Contacts do
  @moduledoc """
  Local contact management and read-only imported address books.
  """

  import Ecto.Query
  alias Manifold.Data.Schema.{Contact, ICloudConnection}
  alias Manifold.Repo

  def list_contacts(opts \\ []) do
    limit = bounded_integer(Keyword.get(opts, :limit), 100, 1, 500)
    offset = bounded_integer(Keyword.get(opts, :offset), 0, 0, 1_000_000)

    Contact
    |> search(Keyword.get(opts, :search))
    |> order_by([contact], asc: fragment("lower(?)", contact.full_name), asc: contact.id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> preload_sources()
  end

  def get_contact(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Contact{} = contact <- Repo.get(Contact, uuid) do
      preload_sources(contact)
    else
      _ -> nil
    end
  end

  def create_contact(attrs) do
    %Contact{}
    |> Contact.local_changeset(attrs)
    |> Repo.insert()
  end

  def update_contact(id, attrs) do
    case get_contact(id) do
      nil ->
        {:error, :not_found}

      %Contact{collection_id: nil} = contact ->
        contact |> Contact.local_changeset(attrs) |> Repo.update()

      %Contact{} ->
        {:error, :read_only}
    end
  end

  def delete_contact(id) do
    case get_contact(id) do
      nil -> {:error, :not_found}
      %Contact{collection_id: nil} = contact -> Repo.delete(contact)
      %Contact{} -> {:error, :read_only}
    end
  end

  def change_contact(contact, attrs \\ %{}), do: Contact.local_changeset(contact, attrs)

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

    Repo.preload(contacts, collection: [connection: connection_query])
  end

  defp bounded_integer(value, _default, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp bounded_integer(_, default, _, _), do: default
end
