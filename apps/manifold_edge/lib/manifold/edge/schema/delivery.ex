defmodule Manifold.Edge.Schema.Delivery do
  @moduledoc false

  use Manifold.Edge.Schema
  import Ecto.Changeset

  schema "edge_deliveries" do
    field(:ingest_id, :string)
    field(:snapshot_revision, :integer)
    field(:peer_ip, :string)
    field(:helo, :string)
    field(:envelope_from, :string)
    field(:received_at, :utc_datetime_usec)
    field(:raw_size, :integer)
    field(:raw_sha256, :string)
    field(:spool_bundle_path, :string)
    field(:state, :string, default: "ready")
    field(:local_delivery_id, :binary_id)
    field(:acknowledged_at, :utc_datetime_usec)
    field(:last_error, :string)

    belongs_to(:route_snapshot, Manifold.Edge.Schema.InstalledRouteSnapshot)

    has_many(:recipients, Manifold.Edge.Schema.DeliveryRecipient, preload_order: [asc: :position])

    has_many(:events, Manifold.Edge.Schema.DeliveryEvent,
      preload_order: [asc: :occurred_at, asc: :inserted_at]
    )

    timestamps(type: :utc_datetime_usec)
  end

  @spec acceptance_changeset(t(), map()) :: Ecto.Changeset.t()
  def acceptance_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :ingest_id,
      :route_snapshot_id,
      :snapshot_revision,
      :peer_ip,
      :helo,
      :envelope_from,
      :received_at,
      :raw_size,
      :raw_sha256,
      :spool_bundle_path,
      :state
    ])
    |> validate_required([
      :ingest_id,
      :route_snapshot_id,
      :snapshot_revision,
      :peer_ip,
      :received_at,
      :raw_size,
      :raw_sha256,
      :spool_bundle_path,
      :state
    ])
    |> validate_number(:snapshot_revision, greater_than_or_equal_to: 0)
    |> validate_number(:raw_size, greater_than_or_equal_to: 0)
    |> validate_format(:raw_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_inclusion(:state, ["ready"])
    |> unique_constraint(:ingest_id)
    |> foreign_key_constraint(:route_snapshot_id)
  end

  @spec acknowledgement_changeset(t(), map()) :: Ecto.Changeset.t()
  def acknowledgement_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:state, :local_delivery_id, :acknowledged_at])
    |> validate_required([:state, :local_delivery_id, :acknowledged_at])
    |> validate_inclusion(:state, ["acknowledged"])
  end

  @spec failure_changeset(t(), map()) :: Ecto.Changeset.t()
  def failure_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:state, :last_error])
    |> validate_required([:state, :last_error])
    |> validate_inclusion(:state, ["failed"])
  end

  @spec recovery_changeset(t(), map()) :: Ecto.Changeset.t()
  def recovery_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:state, :last_error])
    |> validate_required([:state])
    |> validate_inclusion(:state, ["ready"])
  end

  @spec operational_error_changeset(t(), map()) :: Ecto.Changeset.t()
  def operational_error_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:last_error])
    |> validate_required([:last_error])
  end
end
