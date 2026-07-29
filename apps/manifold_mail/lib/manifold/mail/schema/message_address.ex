defmodule Manifold.Mail.Schema.MessageAddress do
  @moduledoc false

  use Manifold.Mail.Schema
  import Ecto.Changeset

  @kinds ~w(from sender reply_to to cc bcc)

  schema "message_addresses" do
    field(:message_id, :binary_id)
    field(:kind, :string)
    field(:position, :integer)
    field(:display_name, :string)
    field(:address, :string)
    field(:canonical_address, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(address, attrs) do
    address
    |> cast(attrs, [
      :message_id,
      :kind,
      :position,
      :display_name,
      :address,
      :canonical_address
    ])
    |> validate_required([:message_id, :kind, :position, :address, :canonical_address])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_length(:address, min: 1, max: 998)
    |> validate_length(:canonical_address, min: 1, max: 998)
    |> unique_constraint([:message_id, :kind, :position],
      name: :message_addresses_message_id_kind_position_index
    )
    |> foreign_key_constraint(:message_id, name: :message_addresses_message_id_fkey)
    |> check_constraint(:kind, name: :message_addresses_kind_valid)
    |> check_constraint(:position, name: :message_addresses_position_nonnegative)
  end
end
