defmodule Manifold.Connectors.Schema.SendMethod do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  @statuses ~w(connected failed disconnected reconnect_required)
  @kinds ~w(smtp)

  schema "connector_send_methods" do
    field(:account_id, :binary_id, source: :mailbox_id)
    field(:kind, :string)
    field(:email_address, :string)
    field(:status, :string, default: "connected")
    field(:enabled, :boolean, default: false)
    field(:last_verified_at, :utc_datetime_usec)
    field(:last_error_class, :string)
    field(:last_error_code, :string)
    field(:last_error_message, :string)
    field(:disconnected_at, :utc_datetime_usec)
    field(:lock_version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(send_method, attrs) do
    send_method
    |> cast(attrs, [
      :account_id,
      :kind,
      :email_address,
      :status,
      :enabled,
      :last_verified_at,
      :last_error_class,
      :last_error_code,
      :last_error_message,
      :disconnected_at
    ])
    |> validate_required([:account_id, :kind, :email_address, :status, :enabled])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:email_address, min: 3, max: 998)
    |> validate_length(:last_error_message, max: 1_000)
    |> optimistic_lock(:lock_version)
  end
end
