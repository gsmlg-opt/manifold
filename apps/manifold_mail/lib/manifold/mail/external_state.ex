defmodule Manifold.Mail.ExternalState do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Core.Error
  alias Manifold.Mail.Folders
  alias Manifold.Mail.Schema.MailboxEntry
  alias Manifold.Repo

  @folder_kinds ~w(inbox archive trash)

  @type normalized_state :: %{
          required(:folder_kind) => String.t() | nil,
          required(:read?) => boolean(),
          required(:starred?) => boolean(),
          required(:deleted?) => boolean()
        }

  @spec apply(Ecto.UUID.t(), Ecto.UUID.t(), normalized_state()) ::
          {:ok, :applied} | {:error, Error.t()}
  def apply(mailbox_id, inbound_delivery_id, state) do
    with {:ok, target_kind, read?, starred?} <- validate_state(state) do
      Repo.transaction(fn ->
        with {:ok, folders} <- Folders.ensure(mailbox_id),
             %MailboxEntry{} = entry <- projected_entry(mailbox_id, inbound_delivery_id) do
          apply_entry(
            entry,
            Map.fetch!(folders, String.to_existing_atom(target_kind)),
            read?,
            starred?
          )
        else
          nil -> Repo.rollback(:projection_pending)
          {:error, reason} -> Repo.rollback({:folder_setup_failed, reason})
        end
      end)
      |> normalize_transaction()
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, database_error(:unavailable)}
  end

  defp validate_state(%{
         folder_kind: folder_kind,
         read?: read?,
         starred?: starred?,
         deleted?: deleted?
       })
       when is_boolean(read?) and is_boolean(starred?) and is_boolean(deleted?) do
    cond do
      deleted? -> {:ok, "trash", read?, starred?}
      folder_kind in @folder_kinds -> {:ok, folder_kind, read?, starred?}
      true -> {:error, invalid_state_error()}
    end
  end

  defp validate_state(_state), do: {:error, invalid_state_error()}

  defp projected_entry(mailbox_id, inbound_delivery_id) do
    MailboxEntry
    |> where(
      [entry],
      entry.mailbox_id == ^mailbox_id and
        entry.inbound_delivery_id == ^inbound_delivery_id and
        not is_nil(entry.message_id) and
        not is_nil(entry.folder_id) and
        not is_nil(entry.thread_id)
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp apply_entry(entry, folder, read?, starred?) do
    if current_state?(entry, folder.id, read?, starred?) do
      :applied
    else
      now = DateTime.utc_now()

      entry
      |> MailboxEntry.changeset(%{
        folder_id: folder.id,
        previous_folder_id: nil,
        read_at: state_timestamp(entry.read_at, read?, now),
        starred_at: state_timestamp(entry.starred_at, starred?, now)
      })
      |> Repo.update()
      |> case do
        {:ok, _entry} -> :applied
        {:error, changeset} -> Repo.rollback({:update_failed, changeset.errors})
      end
    end
  end

  defp current_state?(entry, folder_id, read?, starred?) do
    entry.folder_id == folder_id and is_nil(entry.previous_folder_id) and
      present?(entry.read_at) == read? and present?(entry.starred_at) == starred?
  end

  defp state_timestamp(existing, true, _now) when not is_nil(existing), do: existing
  defp state_timestamp(_existing, true, now), do: now
  defp state_timestamp(_existing, false, _now), do: nil

  defp present?(value), do: not is_nil(value)

  defp normalize_transaction({:ok, :applied}), do: {:ok, :applied}

  defp normalize_transaction({:error, :projection_pending}) do
    {:error,
     Error.new(
       :temporary,
       :projection_pending,
       "mail projection is not available yet"
     )}
  end

  defp normalize_transaction({:error, reason}), do: {:error, database_error(reason)}

  defp invalid_state_error do
    Error.new(
      :permanent,
      :invalid_external_state,
      "external provider state is invalid"
    )
  end

  defp database_error(reason) do
    Error.new(
      :temporary,
      :database_unavailable,
      "external mail state could not be persisted",
      %{reason: inspect(reason)}
    )
  end
end
