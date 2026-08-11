defmodule Manifold.Connectors.Schema.ReceiveMethod do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  @statuses ~w(connected syncing reconnect_required failed disconnected not_implemented)
  @kinds ~w(gmail microsoft imap pop3 eas ews)

  schema "connector_accounts" do
    field(:account_id, :binary_id, source: :mailbox_id)
    field(:oauth_authorization_id, :binary_id)
    field(:kind, :string, source: :provider)
    field(:provider_account_id, :string)
    field(:email_address, :string)
    field(:status, :string, default: "connected")
    field(:enabled, :boolean, default: false)
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

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec implemented_kinds() :: [String.t()]
  def implemented_kinds, do: ~w(gmail microsoft imap eas)

  @spec placeholder_kinds() :: [String.t()]
  def placeholder_kinds, do: ~w(pop3 ews)

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(receive_method, attrs) do
    receive_method
    |> cast(attrs, [
      :account_id,
      :oauth_authorization_id,
      :kind,
      :provider_account_id,
      :email_address,
      :status,
      :enabled,
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
      :account_id,
      :kind,
      :provider_account_id,
      :email_address,
      :status,
      :enabled,
      :sync_enabled,
      :granted_scopes
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:provider_account_id, min: 1, max: 255)
    |> validate_length(:email_address, min: 3, max: 998)
    |> validate_length(:last_error_message, max: 1_000)
    |> foreign_key_constraint(:oauth_authorization_id)
    |> unique_constraint([:kind, :provider_account_id],
      name: :connector_accounts_provider_account_index
    )
    |> optimistic_lock(:lock_version)
  end
end
