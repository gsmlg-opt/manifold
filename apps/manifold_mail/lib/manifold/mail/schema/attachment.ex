defmodule Manifold.Mail.Schema.Attachment do
  @moduledoc false

  use Manifold.Mail.Schema
  import Ecto.Changeset

  @dispositions ~w(attachment inline unspecified)

  schema "attachments" do
    field(:message_id, :binary_id)
    field(:part_path, :string)
    field(:content_id, :string)
    field(:filename, :string)
    field(:media_type, :string)
    field(:disposition, :string, default: "unspecified")
    field(:size, :integer)
    field(:sha256, :string)
    field(:object_key, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :message_id,
      :part_path,
      :content_id,
      :filename,
      :media_type,
      :disposition,
      :size,
      :sha256,
      :object_key
    ])
    |> validate_required([
      :message_id,
      :part_path,
      :media_type,
      :disposition,
      :size,
      :sha256,
      :object_key
    ])
    |> validate_inclusion(:disposition, @dispositions)
    |> validate_number(:size, greater_than_or_equal_to: 0)
    |> validate_format(:sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:part_path, min: 1, max: 255)
    |> unique_constraint([:message_id, :part_path],
      name: :attachments_message_id_part_path_index
    )
    |> foreign_key_constraint(:message_id, name: :attachments_message_id_fkey)
    |> check_constraint(:size, name: :attachments_size_nonnegative)
    |> check_constraint(:disposition, name: :attachments_disposition_valid)
  end
end
