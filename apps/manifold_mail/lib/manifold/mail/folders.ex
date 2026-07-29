defmodule Manifold.Mail.Folders do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Mail.Schema.Folder
  alias Manifold.Repo

  @system_folders [{"inbox", "Inbox"}, {"archive", "Archive"}, {"trash", "Trash"}]

  @spec ensure(Ecto.UUID.t()) ::
          {:ok, %{inbox: Folder.t(), archive: Folder.t(), trash: Folder.t()}}
  def ensure(mailbox_id) do
    now = DateTime.utc_now()

    rows =
      Enum.map(@system_folders, fn {kind, name} ->
        %{
          id: Ecto.UUID.generate(),
          mailbox_id: mailbox_id,
          kind: kind,
          name: name,
          normalized_name: String.downcase(name),
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Folder, rows,
      on_conflict: :nothing,
      conflict_target: [:mailbox_id, :normalized_name]
    )

    folders =
      Folder
      |> where(
        [folder],
        folder.mailbox_id == ^mailbox_id and folder.kind in ^~w(inbox archive trash)
      )
      |> Repo.all()
      |> Map.new(&{String.to_existing_atom(&1.kind), &1})

    case folders do
      %{inbox: _inbox, archive: _archive, trash: _trash} -> {:ok, folders}
      _other -> {:error, :system_folders_unavailable}
    end
  end

  @spec get_system(Ecto.UUID.t(), String.t()) :: Folder.t() | nil
  def get_system(mailbox_id, kind) when kind in ~w(inbox archive trash) do
    Repo.get_by(Folder, mailbox_id: mailbox_id, kind: kind)
  end

  @spec belongs_to_mailbox?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def belongs_to_mailbox?(folder_id, mailbox_id) do
    Repo.exists?(
      from(folder in Folder,
        where: folder.id == ^folder_id and folder.mailbox_id == ^mailbox_id
      )
    )
  end
end
