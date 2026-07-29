defmodule Manifold.Ingest.Schema.CloudIngressIdentity do
  @moduledoc false

  use Manifold.Ingest.Schema
  import Ecto.Changeset

  alias Manifold.Ingest.Schema.InboundDelivery

  schema "cloud_ingress_identities" do
    field(:source_id, :string)
    field(:external_delivery_id, :string)
    field(:raw_sha256, :string)
    field(:raw_size, :integer)
    field(:routes_sha256, :string)

    belongs_to(:inbound_delivery, InboundDelivery)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [
      :source_id,
      :external_delivery_id,
      :inbound_delivery_id,
      :raw_sha256,
      :raw_size,
      :routes_sha256
    ])
    |> validate_required([
      :source_id,
      :external_delivery_id,
      :inbound_delivery_id,
      :raw_sha256,
      :raw_size,
      :routes_sha256
    ])
    |> validate_length(:source_id, max: 255)
    |> validate_length(:external_delivery_id, max: 255)
    |> validate_number(:raw_size, greater_than_or_equal_to: 0)
    |> unique_constraint([:source_id, :external_delivery_id],
      name: :cloud_ingress_identities_source_delivery_index
    )
    |> unique_constraint(:inbound_delivery_id,
      name: :cloud_ingress_identities_inbound_delivery_index
    )
  end
end
