defmodule Manifold.Accounts.Schema.Owner do
  @moduledoc false

  use Manifold.Accounts.Schema
  import Ecto.Changeset

  schema "owners" do
    field(:email, :string)
    field(:hashed_password, :string)
    field(:password, :string, virtual: true, redact: true)

    timestamps(type: :utc_datetime_usec)
  end

  def registration_changeset(owner, attrs) do
    owner
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/)
    |> validate_length(:password, min: 12, max: 128)
    |> unique_constraint(:email)
    |> put_password_hash()
  end

  defp put_password_hash(
         %Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset
       ) do
    put_change(changeset, :hashed_password, Bcrypt.hash_pwd_salt(password))
  end

  defp put_password_hash(changeset), do: changeset
end
