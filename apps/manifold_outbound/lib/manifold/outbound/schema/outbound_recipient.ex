defmodule Manifold.Outbound.Schema.OutboundRecipient do
  @moduledoc false

  use Manifold.Outbound.Schema
  import Ecto.Changeset

  schema "outbound_recipients" do
    field(:outbound_message_id, :binary_id)
    field(:kind, :string)
    field(:position, :integer)
    field(:display_name, :string)
    field(:address, :string)
    field(:canonical_address, :string)
    field(:delivery_state, :string, default: "pending")
    field(:last_event_at, :utc_datetime_usec)
    field(:status_detail, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(recipient, attrs) do
    recipient
    |> cast(attrs, [
      :outbound_message_id,
      :kind,
      :position,
      :display_name,
      :address,
      :canonical_address,
      :delivery_state,
      :last_event_at,
      :status_detail
    ])
    |> validate_required([
      :outbound_message_id,
      :kind,
      :position,
      :address,
      :canonical_address,
      :delivery_state
    ])
    |> validate_inclusion(:kind, ~w(to cc bcc))
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:outbound_message_id)
    |> unique_constraint([:outbound_message_id, :kind, :position])
    |> unique_constraint([:outbound_message_id, :canonical_address])
    |> check_constraint(:kind, name: :outbound_recipients_kind_valid)
    |> check_constraint(:position, name: :outbound_recipients_position_nonnegative)
    |> check_constraint(:delivery_state, name: :outbound_recipients_delivery_state_valid)
  end
end
