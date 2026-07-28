defmodule Manifold.Accounts.Schema.Domain do
  @moduledoc false

  use Manifold.Accounts.Schema
  import Ecto.Changeset

  alias Manifold.Core.Domain, as: DomainNormalizer

  schema "domains" do
    field(:name, :string)
    field(:normalized_domain, :string)
    field(:active, :boolean, default: true)
    field(:plus_addressing_enabled, :boolean, default: true)

    has_many(:mailboxes, Manifold.Accounts.Schema.Mailbox)
    has_many(:aliases, Manifold.Accounts.Schema.Alias)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [:name, :active, :plus_addressing_enabled])
    |> validate_required([:name])
    |> normalize_domain()
    |> unique_constraint(:normalized_domain)
  end

  defp normalize_domain(%Ecto.Changeset{} = changeset) do
    case fetch_change(changeset, :name) do
      {:ok, name} ->
        case DomainNormalizer.normalize(name) do
          {:ok, normalized} -> put_change(changeset, :normalized_domain, normalized)
          {:error, error} -> add_error(changeset, :name, error.message)
        end

      :error ->
        changeset
    end
  end
end
