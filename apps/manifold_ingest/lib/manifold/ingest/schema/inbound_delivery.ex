defmodule Manifold.Ingest.Schema.InboundDelivery do
  @moduledoc false

  use Manifold.Ingest.Schema
  import Ecto.Changeset

  alias Manifold.Storage.Spool.Bundle

  schema "inbound_deliveries" do
    field(:ingest_id, :string)
    field(:source_kind, :string, default: "smtp")
    field(:storage_domain_id, :binary_id)
    field(:peer_ip, :string)
    field(:helo, :string)
    field(:envelope_from, :string)
    field(:received_at, :utc_datetime_usec)
    field(:raw_size, :integer)
    field(:raw_sha256, :string)
    field(:spool_bundle_path, :string)
    field(:raw_object_key, :string)
    field(:raw_storage_state, :string, default: "spooled")
    field(:processing_state, :string, default: "accepted")
    field(:last_error, :string)

    has_many(:delivery_recipients, Manifold.Ingest.Schema.DeliveryRecipient)
    has_many(:message_events, Manifold.Ingest.Schema.MessageEvent)

    timestamps(type: :utc_datetime_usec)
  end

  def acceptance_changeset(delivery, %Bundle{} = bundle, overrides \\ %{}) do
    manifest = bundle.manifest

    attrs = %{
      ingest_id: manifest.ingest_id,
      source_kind: Map.get(overrides, :source_kind, manifest.source_kind || "smtp"),
      storage_domain_id: Map.get(overrides, :storage_domain_id, manifest.storage_domain_id),
      peer_ip: manifest.peer_ip,
      helo: manifest.helo,
      envelope_from: manifest.envelope_from,
      received_at: manifest.received_at,
      raw_size: manifest.raw_size,
      raw_sha256: manifest.raw_sha256,
      spool_bundle_path: bundle.path,
      raw_storage_state: "spooled",
      processing_state: "accepted"
    }

    delivery
    |> cast(attrs, [
      :ingest_id,
      :source_kind,
      :storage_domain_id,
      :peer_ip,
      :helo,
      :envelope_from,
      :received_at,
      :raw_size,
      :raw_sha256,
      :spool_bundle_path,
      :raw_storage_state,
      :processing_state
    ])
    |> validate_required([
      :ingest_id,
      :source_kind,
      :storage_domain_id,
      :received_at,
      :raw_size,
      :raw_sha256,
      :spool_bundle_path,
      :raw_storage_state,
      :processing_state
    ])
    |> validate_inclusion(:source_kind, ["smtp", "edge_smtp", "provider_import"])
    |> validate_peer_ip()
    |> unique_constraint(:ingest_id)
  end

  def state_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:raw_object_key, :raw_storage_state, :processing_state, :last_error])
    |> validate_required([:raw_storage_state, :processing_state])
  end

  defp validate_peer_ip(changeset) do
    case get_field(changeset, :source_kind) do
      "provider_import" -> changeset
      _other -> validate_required(changeset, [:peer_ip])
    end
  end
end
