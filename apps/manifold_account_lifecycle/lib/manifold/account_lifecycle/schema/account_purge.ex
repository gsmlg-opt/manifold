defmodule Manifold.AccountLifecycle.Schema.AccountPurge do
  @moduledoc false

  use Manifold.AccountLifecycle.Schema
  import Ecto.Changeset

  @statuses ~w(requested running failed completed)
  @stages ~w(discover drain connectors outbound mailbox_copy orphan_payloads objects finalize completed)
  @counters [
    :discovered_deliveries,
    :purged_deliveries,
    :shared_retained_deliveries,
    :deleted_objects
  ]

  schema "account_purges" do
    field(:mailbox_id, :binary_id)
    field(:status, :string, default: "requested")
    field(:stage, :string, default: "discover")
    field(:progress, :map, default: %{})
    field(:error_class, :string)
    field(:error_code, :string)
    field(:error_message, :string)
    field(:discovered_deliveries, :integer, default: 0)
    field(:purged_deliveries, :integer, default: 0)
    field(:shared_retained_deliveries, :integer, default: 0)
    field(:deleted_objects, :integer, default: 0)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(purge, attrs) do
    purge
    |> cast(attrs, [
      :mailbox_id,
      :status,
      :stage,
      :progress,
      :error_class,
      :error_code,
      :error_message,
      :discovered_deliveries,
      :purged_deliveries,
      :shared_retained_deliveries,
      :deleted_objects,
      :started_at,
      :completed_at
    ])
    |> validate_required([:mailbox_id, :status, :stage, :progress] ++ @counters)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:stage, @stages)
    |> validate_counters()
    |> unique_constraint(:mailbox_id)
    |> check_constraint(:status, name: :account_purges_status_valid)
    |> check_constraint(:stage, name: :account_purges_stage_valid)
    |> check_constraint(:discovered_deliveries, name: :account_purges_counters_nonnegative)
  end

  defp validate_counters(changeset) do
    Enum.reduce(@counters, changeset, fn counter, acc ->
      validate_number(acc, counter, greater_than_or_equal_to: 0)
    end)
  end
end
