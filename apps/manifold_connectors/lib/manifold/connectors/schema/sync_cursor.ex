defmodule Manifold.Connectors.Schema.SyncCursor do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  schema "connector_sync_cursors" do
    field(:external_account_id, :binary_id)
    field(:scope, :string)
    field(:phase, :string, default: "bootstrap")
    field(:bootstrap_cursor, :string)
    field(:page_cursor, :string)
    field(:committed_cursor, :string)
    field(:metadata, :map, default: %{})
    field(:generation, :integer, default: 1)
    field(:last_completed_at, :utc_datetime_usec)
    field(:lock_version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [
      :external_account_id,
      :scope,
      :phase,
      :bootstrap_cursor,
      :page_cursor,
      :committed_cursor,
      :metadata,
      :generation,
      :last_completed_at
    ])
    |> validate_required([:external_account_id, :scope, :phase, :metadata, :generation])
    |> validate_length(:scope, min: 1, max: 512)
    |> validate_length(:phase, min: 1, max: 32)
    |> unique_constraint([:external_account_id, :scope],
      name: :connector_sync_cursors_account_scope_index
    )
    |> optimistic_lock(:lock_version)
  end
end
