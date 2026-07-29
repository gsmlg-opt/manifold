defmodule Manifold.Mail.Schema.MessageHeader do
  @moduledoc false

  use Manifold.Mail.Schema
  import Ecto.Changeset

  schema "message_headers" do
    field(:message_id, :binary_id)
    field(:position, :integer)
    field(:original_name, :string)
    field(:normalized_name, :string)
    field(:unfolded_value, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(header, attrs) do
    header
    |> cast(attrs, [:message_id, :position, :original_name, :normalized_name, :unfolded_value])
    |> validate_required([
      :message_id,
      :position,
      :original_name,
      :normalized_name,
      :unfolded_value
    ])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_length(:original_name, min: 1, max: 998)
    |> validate_length(:normalized_name, min: 1, max: 998)
    |> unique_constraint([:message_id, :position],
      name: :message_headers_message_id_position_index
    )
    |> foreign_key_constraint(:message_id, name: :message_headers_message_id_fkey)
    |> check_constraint(:position, name: :message_headers_position_nonnegative)
  end
end
