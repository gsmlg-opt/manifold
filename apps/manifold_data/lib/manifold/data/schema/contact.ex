defmodule Manifold.Data.Schema.Contact do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @local_fields [
    :full_name,
    :given_name,
    :family_name,
    :organization,
    :notes,
    :emails,
    :phones,
    :addresses
  ]
  @postal_fields [:street, :locality, :region, :postal_code, :country, :po_box, :extended_address]

  schema "contacts" do
    field(:resource_href, :string)
    field(:uid, :string)
    field(:etag, :string)
    field(:raw, :string)
    field(:full_name, :string)
    field(:given_name, :string)
    field(:family_name, :string)
    field(:organization, :string)
    field(:notes, :string)
    field(:emails, {:array, :map}, default: [])
    field(:phones, {:array, :map}, default: [])
    field(:addresses, {:array, :map}, default: [])
    belongs_to(:collection, Manifold.Data.Schema.DAVCollection)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, @local_fields ++ [:collection_id, :resource_href, :uid, :etag, :raw])
    |> validate_required([:full_name, :emails, :phones, :addresses])
    |> foreign_key_constraint(:collection_id)
    |> unique_constraint([:collection_id, :resource_href], error_key: :resource_href)
    |> check_constraint(:collection_id, name: :contacts_source_identity_valid)
    |> check_constraint(:full_name, name: :contacts_full_name_present)
  end

  def local_changeset(contact, attrs) do
    contact
    |> cast(attrs, @local_fields)
    |> update_change(:full_name, &String.trim/1)
    |> validate_required([:full_name, :emails, :phones, :addresses])
    |> validate_length(:full_name, max: 512)
    |> validate_length(:given_name, max: 512)
    |> validate_length(:family_name, max: 512)
    |> validate_length(:organization, max: 512)
    |> validate_length(:notes, max: 10_000)
    |> validate_values(:emails, &valid_email?/1)
    |> validate_values(:phones, &present_string?/1)
    |> validate_values(:addresses, &valid_address?/1)
    |> check_constraint(:full_name, name: :contacts_full_name_present)
  end

  defp validate_values(changeset, field, valid?) do
    validate_change(changeset, field, fn _, values ->
      if length(values) <= 100 and Enum.all?(values, valid?),
        do: [],
        else: [{field, "must contain valid contact values (at most 100)"}]
    end)
  end

  defp valid_email?(value) do
    case Map.get(value, "value", Map.get(value, :value)) do
      email when is_binary(email) ->
        byte_size(email) <= 320 and Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u, email)

      _ ->
        false
    end
  end

  defp present_string?(value) when is_map(value),
    do: present_string?(Map.get(value, "value", Map.get(value, :value)))

  defp present_string?(value) when is_binary(value),
    do: String.trim(value) != "" and byte_size(value) <= 4096

  defp present_string?(_), do: false

  defp valid_address?(address) do
    values = Enum.map(@postal_fields, &Map.get(address, Atom.to_string(&1), Map.get(address, &1)))
    Enum.all?(values, &(is_nil(&1) or is_binary(&1))) and Enum.any?(values, &present_string?/1)
  end
end
