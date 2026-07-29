defmodule Manifold.Outbound.Schema.OutboundMessage do
  @moduledoc false

  use Manifold.Outbound.Schema
  import Ecto.Changeset

  alias Manifold.Outbound.State

  schema "outbound_messages" do
    field(:mailbox_id, :binary_id)
    field(:state, :string, default: "draft")
    field(:composition_kind, :string, default: "new")
    field(:source_message_id, :binary_id)
    field(:sender_name, :string)
    field(:sender_address, :string)
    field(:canonical_sender_address, :string)
    field(:subject, :string)
    field(:text_body, :string)
    field(:in_reply_to, :string)
    field(:references, {:array, :string}, default: [])
    field(:last_error_class, :string)
    field(:last_error_code, :string)
    field(:last_error_message, :string)
    field(:lock_version, :integer, default: 1)
    field(:queued_at, :utc_datetime_usec)
    field(:accepted_at, :utc_datetime_usec)
    field(:failed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(message, attrs) do
    message
    |> cast(attrs, [
      :mailbox_id,
      :state,
      :composition_kind,
      :source_message_id,
      :sender_name,
      :sender_address,
      :canonical_sender_address,
      :subject,
      :text_body,
      :in_reply_to,
      :references
    ])
    |> validate_required([
      :mailbox_id,
      :state,
      :composition_kind,
      :sender_address,
      :canonical_sender_address
    ])
    |> shared_validations()
    |> foreign_key_constraint(:mailbox_id)
  end

  @spec draft_changeset(t(), map()) :: Ecto.Changeset.t()
  def draft_changeset(message, attrs) do
    message
    |> cast(attrs, [:subject, :text_body])
    |> shared_validations()
    |> optimistic_lock(:lock_version)
  end

  @spec queue_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def queue_changeset(message, now) do
    message
    |> change(
      state: "queued",
      queued_at: now,
      last_error_class: nil,
      last_error_code: nil,
      last_error_message: nil
    )
    |> optimistic_lock(:lock_version)
  end

  defp shared_validations(changeset) do
    changeset
    |> validate_inclusion(:state, State.states())
    |> validate_inclusion(:composition_kind, ~w(new reply reply_all forward))
    |> validate_length(:subject, max: 998, count: :bytes)
    |> validate_length(:text_body, max: 10 * 1024 * 1024, count: :bytes)
    |> validate_number(:lock_version, greater_than: 0)
    |> check_constraint(:state, name: :outbound_messages_state_valid)
    |> check_constraint(:composition_kind, name: :outbound_messages_composition_kind_valid)
    |> check_constraint(:subject, name: :outbound_messages_subject_size)
    |> check_constraint(:text_body, name: :outbound_messages_body_size)
    |> check_constraint(:lock_version, name: :outbound_messages_lock_version_positive)
  end
end
