defmodule Manifold.Accounts.Schema.AliasTarget do
  @moduledoc false

  use Manifold.Accounts.Schema
  import Ecto.Changeset

  schema "alias_targets" do
    field(:active, :boolean, default: true)

    belongs_to(:alias, Manifold.Accounts.Schema.Alias)
    belongs_to(:mailbox, Manifold.Accounts.Schema.Mailbox)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(target, attrs) do
    target
    |> cast(attrs, [:alias_id, :mailbox_id, :active])
    |> validate_required([:alias_id, :mailbox_id])
    |> unique_constraint([:alias_id, :mailbox_id])
  end
end
