defmodule Manifold.Connectors.Schema.EasSettings do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  @default_path "/Microsoft-Server-ActiveSync"
  @default_device_type "Manifold"
  @default_protocol_version "14.1"

  schema "connector_eas_settings" do
    field(:external_account_id, :binary_id)
    field(:host, :string)
    field(:port, :integer)
    field(:path, :string, default: @default_path)
    field(:username, :string)
    field(:device_id, :string)
    field(:device_type, :string, default: @default_device_type)
    field(:protocol_version, :string, default: @default_protocol_version)
    field(:policy_key, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec default_path() :: String.t()
  def default_path, do: @default_path

  @spec default_device_type() :: String.t()
  def default_device_type, do: @default_device_type

  @spec default_protocol_version() :: String.t()
  def default_protocol_version, do: @default_protocol_version

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :external_account_id,
      :host,
      :port,
      :path,
      :username,
      :device_id,
      :device_type,
      :protocol_version,
      :policy_key
    ])
    |> validate_required([
      :external_account_id,
      :host,
      :port,
      :path,
      :username,
      :device_id,
      :device_type,
      :protocol_version
    ])
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_length(:host, min: 1, max: 253)
    |> validate_length(:path, min: 1, max: 255)
    |> validate_length(:username, min: 1, max: 320)
    |> validate_length(:device_id, min: 1, max: 32)
    |> validate_length(:device_type, min: 1, max: 32)
    |> validate_length(:protocol_version, min: 1, max: 16)
    |> validate_length(:policy_key, max: 64)
    |> unique_constraint(:external_account_id)
  end
end
