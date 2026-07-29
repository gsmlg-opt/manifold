defmodule Manifold.Edge.Schema.DeliveryRecipient do
  @moduledoc false

  use Manifold.Edge.Schema
  import Ecto.Changeset

  schema "edge_delivery_recipients" do
    field(:position, :integer)
    field(:original_address, :string)
    field(:canonical_address, :string)
    field(:plus_tag, :string)
    field(:domain_id, :string)
    field(:mailbox_ids, {:array, :string}, default: [])

    belongs_to(:delivery, Manifold.Edge.Schema.Delivery)

    timestamps(type: :utc_datetime_usec)
  end

  @spec acceptance_changeset(t(), map()) :: Ecto.Changeset.t()
  def acceptance_changeset(recipient, attrs) do
    recipient
    |> cast(attrs, [
      :delivery_id,
      :position,
      :original_address,
      :canonical_address,
      :plus_tag,
      :domain_id,
      :mailbox_ids
    ])
    |> validate_required([
      :delivery_id,
      :position,
      :original_address,
      :canonical_address,
      :domain_id,
      :mailbox_ids
    ])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_length(:mailbox_ids, min: 1)
    |> foreign_key_constraint(:delivery_id)
    |> unique_constraint([:delivery_id, :position])
  end
end
