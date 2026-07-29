defmodule Manifold.Outbound.Schema.ProviderEvent do
  @moduledoc false

  use Manifold.Outbound.Schema
  import Ecto.Changeset

  schema "provider_events" do
    field(:outbound_message_id, :binary_id)
    field(:provider, :string)
    field(:provider_event_id, :string)
    field(:provider_message_id, :string)
    field(:event_type, :string)
    field(:normalized_state, :string)
    field(:metadata, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)
    field(:received_at, :utc_datetime_usec)
    field(:processing_state, :string, default: "pending")
    field(:processed_at, :utc_datetime_usec)
    field(:last_error, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :outbound_message_id,
      :provider,
      :provider_event_id,
      :provider_message_id,
      :event_type,
      :normalized_state,
      :metadata,
      :occurred_at,
      :received_at,
      :processing_state,
      :processed_at,
      :last_error
    ])
    |> validate_required([
      :provider,
      :provider_event_id,
      :provider_message_id,
      :event_type,
      :normalized_state,
      :occurred_at,
      :received_at,
      :processing_state
    ])
    |> validate_inclusion(:processing_state, ~w(pending processed unmatched failed))
    |> unique_constraint([:provider, :provider_event_id])
    |> foreign_key_constraint(:outbound_message_id)
    |> check_constraint(:processing_state, name: :provider_events_processing_state_valid)
  end
end
