defmodule Manifold.Connectors.Schema.RemoteMessage do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  @states ~w(pending imported deleted failed)

  schema "connector_remote_messages" do
    field(:external_account_id, :binary_id)
    field(:provider_message_id, :string)
    field(:provider_thread_id, :string)
    field(:inbound_delivery_id, :binary_id)
    field(:provider_received_at, :utc_datetime_usec)
    field(:remote_folder_id, :string)
    field(:remote_folder_kind, :string)
    field(:remote_labels, {:array, :string}, default: [])
    field(:remote_read, :boolean, default: false)
    field(:remote_starred, :boolean, default: false)
    field(:remote_deleted, :boolean, default: false)
    field(:state, :string, default: "pending")
    field(:last_error_class, :string)
    field(:last_error_code, :string)
    field(:last_error_message, :string)
    field(:synced_at, :utc_datetime_usec)
    field(:lock_version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :external_account_id,
      :provider_message_id,
      :provider_thread_id,
      :inbound_delivery_id,
      :provider_received_at,
      :remote_folder_id,
      :remote_folder_kind,
      :remote_labels,
      :remote_read,
      :remote_starred,
      :remote_deleted,
      :state,
      :last_error_class,
      :last_error_code,
      :last_error_message,
      :synced_at
    ])
    |> validate_required([
      :external_account_id,
      :provider_message_id,
      :remote_labels,
      :remote_read,
      :remote_starred,
      :remote_deleted,
      :state
    ])
    |> validate_inclusion(:state, @states)
    |> validate_length(:provider_message_id, min: 1, max: 512)
    |> validate_length(:last_error_message, max: 1_000)
    |> unique_constraint([:external_account_id, :provider_message_id],
      name: :connector_remote_messages_account_message_index
    )
    |> optimistic_lock(:lock_version)
  end
end
