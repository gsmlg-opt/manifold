defmodule Manifold.Connectors.Schema.ImapSettings do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  @tls_modes ~w(ssl starttls)

  schema "connector_imap_settings" do
    field(:external_account_id, :binary_id)
    field(:host, :string)
    field(:port, :integer)
    field(:tls_mode, :string)
    field(:username, :string)
    field(:mailbox_path, :string, default: "INBOX")

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:external_account_id, :host, :port, :tls_mode, :username, :mailbox_path])
    |> validate_required([
      :external_account_id,
      :host,
      :port,
      :tls_mode,
      :username,
      :mailbox_path
    ])
    |> validate_inclusion(:tls_mode, @tls_modes)
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_length(:host, min: 1, max: 253)
    |> validate_length(:username, min: 1, max: 320)
    |> validate_length(:mailbox_path, min: 1, max: 255)
    |> unique_constraint(:external_account_id)
  end
end
