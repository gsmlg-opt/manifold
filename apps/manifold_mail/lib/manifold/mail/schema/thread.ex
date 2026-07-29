defmodule Manifold.Mail.Schema.Thread do
  @moduledoc false

  use Manifold.Mail.Schema
  import Ecto.Changeset

  schema "mail_threads" do
    field(:mailbox_id, :binary_id)
    field(:subject_summary, :string)
    field(:last_message_at, :utc_datetime_usec)
    field(:message_count, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:mailbox_id, :subject_summary, :last_message_at, :message_count])
    |> validate_required([:mailbox_id, :last_message_at, :message_count])
    |> validate_number(:message_count, greater_than_or_equal_to: 0)
    |> validate_length(:subject_summary, max: 998)
    |> foreign_key_constraint(:mailbox_id, name: :mail_threads_mailbox_id_fkey)
    |> check_constraint(:message_count, name: :mail_threads_message_count_nonnegative)
  end
end
