defmodule Manifold.Ingest.Schema.ExternalIngressIdentity do
  @moduledoc false

  use Manifold.Ingest.Schema
  import Ecto.Changeset

  schema "external_ingress_identities" do
    field(:provider, :string)
    field(:source_id, :string)
    field(:external_message_id, :string)
    field(:mailbox_id, :binary_id)
    field(:raw_size, :integer)
    field(:raw_sha256, :string)
    field(:target_sha256, :string)

    belongs_to(:inbound_delivery, Manifold.Ingest.Schema.InboundDelivery)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [
      :provider,
      :source_id,
      :external_message_id,
      :inbound_delivery_id,
      :mailbox_id,
      :raw_size,
      :raw_sha256,
      :target_sha256
    ])
    |> validate_required([
      :provider,
      :source_id,
      :external_message_id,
      :inbound_delivery_id,
      :mailbox_id,
      :raw_size,
      :raw_sha256,
      :target_sha256
    ])
    |> validate_length(:provider, min: 1, max: 32)
    |> validate_length(:source_id, min: 1, max: 255)
    |> validate_length(:external_message_id, min: 1, max: 512)
    |> unique_constraint([:provider, :source_id, :external_message_id],
      name: :external_ingress_identities_source_message_index
    )
    |> unique_constraint(:inbound_delivery_id)
  end
end
