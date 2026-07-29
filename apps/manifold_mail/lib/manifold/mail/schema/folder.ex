defmodule Manifold.Mail.Schema.Folder do
  @moduledoc false

  use Manifold.Mail.Schema
  import Ecto.Changeset

  @kinds ~w(inbox archive trash custom)

  schema "mailbox_folders" do
    field(:mailbox_id, :binary_id)
    field(:kind, :string)
    field(:name, :string)
    field(:normalized_name, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:mailbox_id, :kind, :name])
    |> validate_required([:mailbox_id, :kind, :name])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:name, min: 1, max: 255)
    |> put_normalized_name()
    |> unique_constraint([:mailbox_id, :normalized_name],
      name: :mailbox_folders_mailbox_id_normalized_name_index
    )
    |> unique_constraint([:mailbox_id, :kind],
      name: :mailbox_folders_mailbox_id_system_kind_index
    )
    |> foreign_key_constraint(:mailbox_id, name: :mailbox_folders_mailbox_id_fkey)
    |> check_constraint(:kind, name: :mailbox_folders_kind_valid)
  end

  defp put_normalized_name(changeset) do
    case get_field(changeset, :name) do
      name when is_binary(name) ->
        put_change(changeset, :normalized_name, name |> String.trim() |> String.downcase())

      _other ->
        changeset
    end
  end
end
