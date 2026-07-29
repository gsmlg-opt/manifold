defmodule Manifold.Security.Schema.SecurityEvent do
  @moduledoc false

  use Manifold.Security.Schema
  import Ecto.Changeset

  schema "security_events" do
    field(:security_assessment_id, :binary_id)
    field(:inbound_delivery_id, :binary_id)
    field(:event_type, :string)
    field(:metadata, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :security_assessment_id,
      :inbound_delivery_id,
      :event_type,
      :metadata,
      :occurred_at
    ])
    |> validate_required([
      :security_assessment_id,
      :inbound_delivery_id,
      :event_type,
      :occurred_at
    ])
    |> foreign_key_constraint(:security_assessment_id)
    |> foreign_key_constraint(:inbound_delivery_id)
  end
end
