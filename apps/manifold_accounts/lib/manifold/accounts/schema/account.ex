defmodule Manifold.Accounts.Schema.Account do
  @moduledoc false

  use Manifold.Accounts.Schema
  import Ecto.Changeset

  schema "mailboxes" do
    field(:local_part, :string)
    field(:canonical_local_part, :string)
    field(:name, :string, source: :display_name)
    field(:active, :boolean, default: true)
    field(:plus_addressing_enabled, :boolean, default: true)

    belongs_to(:domain, Manifold.Accounts.Schema.Domain)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:domain_id, :local_part, :name, :active, :plus_addressing_enabled])
    |> validate_required([:domain_id, :local_part])
    |> validate_format(:local_part, ~r/^[A-Za-z0-9.!#$%&'*+\-\/=?^_`{|}~]+$/)
    |> put_canonical_local_part()
    |> unique_constraint([:domain_id, :canonical_local_part], error_key: :local_part)
  end

  defp put_canonical_local_part(changeset) do
    case get_field(changeset, :local_part) do
      local_part when is_binary(local_part) ->
        put_change(changeset, :canonical_local_part, String.downcase(local_part, :ascii))

      _ ->
        changeset
    end
  end
end
