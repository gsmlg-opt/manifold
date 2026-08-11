defmodule Manifold.Connectors.Schema.ConnectorEvent do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  schema "connector_events" do
    field(:external_account_id, :binary_id)
    field(:oauth_authorization_id, :binary_id)
    field(:event_type, :string)
    field(:metadata, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :external_account_id,
      :oauth_authorization_id,
      :event_type,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:event_type, :metadata, :occurred_at])
    |> validate_anchor()
    |> validate_length(:event_type, min: 1, max: 64)
    |> foreign_key_constraint(:external_account_id)
    |> foreign_key_constraint(:oauth_authorization_id)
    |> check_constraint(:external_account_id, name: :connector_events_anchor_valid)
  end

  defp validate_anchor(changeset) do
    case {
      get_field(changeset, :external_account_id),
      get_field(changeset, :oauth_authorization_id)
    } do
      {external_account_id, nil} when is_binary(external_account_id) -> changeset
      {nil, authorization_id} when is_binary(authorization_id) -> changeset
      _invalid -> add_error(changeset, :external_account_id, "must set exactly one event anchor")
    end
  end
end
