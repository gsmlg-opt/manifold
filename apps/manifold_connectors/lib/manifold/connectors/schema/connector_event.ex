defmodule Manifold.Connectors.Schema.ConnectorEvent do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  schema "connector_events" do
    field(:external_account_id, :binary_id)
    field(:event_type, :string)
    field(:metadata, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:external_account_id, :event_type, :metadata, :occurred_at])
    |> validate_required([:external_account_id, :event_type, :metadata, :occurred_at])
    |> validate_length(:event_type, min: 1, max: 64)
  end
end
