defmodule Manifold.Connectors.Schema.ExternalAccount do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  @statuses ~w(connected syncing reconnect_required failed disconnected)

  schema "connector_accounts" do
    field(:mailbox_id, :binary_id)
    field(:provider, :string)
    field(:provider_account_id, :string)
    field(:email_address, :string)
    field(:status, :string, default: "connected")
    field(:sync_enabled, :boolean, default: true)
    field(:granted_scopes, {:array, :string}, default: [])
    field(:last_attempted_at, :utc_datetime_usec)
    field(:last_synced_at, :utc_datetime_usec)
    field(:last_error_class, :string)
    field(:last_error_code, :string)
    field(:last_error_message, :string)
    field(:disconnected_at, :utc_datetime_usec)
    field(:lock_version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :mailbox_id,
      :provider,
      :provider_account_id,
      :email_address,
      :status,
      :sync_enabled,
      :granted_scopes,
      :last_attempted_at,
      :last_synced_at,
      :last_error_class,
      :last_error_code,
      :last_error_message,
      :disconnected_at
    ])
    |> validate_required([
      :mailbox_id,
      :provider,
      :provider_account_id,
      :email_address,
      :status,
      :sync_enabled,
      :granted_scopes
    ])
    |> validate_inclusion(:provider, ["gmail", "microsoft"])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:provider_account_id, min: 1, max: 255)
    |> validate_length(:email_address, min: 3, max: 998)
    |> validate_length(:last_error_message, max: 1_000)
    |> unique_constraint([:provider, :provider_account_id],
      name: :connector_accounts_provider_account_index
    )
    |> optimistic_lock(:lock_version)
  end
end
