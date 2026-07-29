defmodule Manifold.Mail.Schema.MailboxEntry do
  @moduledoc false

  use Manifold.Mail.Schema
  import Ecto.Changeset

  schema "mailbox_entries" do
    field(:mailbox_id, :binary_id)
    field(:inbound_delivery_id, :binary_id)
    field(:message_id, :binary_id)
    field(:folder_id, :binary_id)
    field(:previous_folder_id, :binary_id)
    field(:thread_id, :binary_id)
    field(:original_recipient, :string)
    field(:read_at, :utc_datetime_usec)
    field(:starred_at, :utc_datetime_usec)
    field(:quarantined, :boolean, default: false)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :mailbox_id,
      :inbound_delivery_id,
      :message_id,
      :folder_id,
      :previous_folder_id,
      :thread_id,
      :original_recipient,
      :read_at,
      :starred_at,
      :quarantined
    ])
    |> validate_required([
      :mailbox_id,
      :inbound_delivery_id,
      :original_recipient,
      :quarantined
    ])
    |> unique_constraint([:mailbox_id, :inbound_delivery_id],
      name: :mailbox_entries_mailbox_id_inbound_delivery_id_index
    )
    |> foreign_key_constraint(:mailbox_id, name: :mailbox_entries_mailbox_id_fkey)
    |> foreign_key_constraint(:inbound_delivery_id,
      name: :mailbox_entries_inbound_delivery_id_fkey
    )
    |> foreign_key_constraint(:message_id, name: :mailbox_entries_message_id_fkey)
    |> foreign_key_constraint(:folder_id, name: :mailbox_entries_folder_id_fkey)
    |> foreign_key_constraint(:previous_folder_id,
      name: :mailbox_entries_previous_folder_id_fkey
    )
    |> foreign_key_constraint(:thread_id, name: :mailbox_entries_thread_id_fkey)
  end
end
