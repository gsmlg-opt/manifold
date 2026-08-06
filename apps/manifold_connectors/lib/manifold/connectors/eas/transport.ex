defmodule Manifold.Connectors.EAS.Transport do
  @moduledoc false

  @type conn :: term()

  @type settings :: %{
          required(:host) => String.t(),
          required(:port) => pos_integer(),
          required(:path) => String.t(),
          required(:username) => String.t(),
          required(:password) => String.t(),
          required(:device_id) => String.t(),
          required(:device_type) => String.t(),
          required(:protocol_version) => String.t(),
          optional(:domain) => String.t() | nil,
          optional(:policy_key) => String.t() | nil,
          optional(:account_id) => String.t(),
          optional(:emit_activity) => boolean()
        }

  @type folder :: %{
          server_id: String.t(),
          display_name: String.t() | nil,
          type: String.t() | nil,
          parent_id: String.t() | nil
        }

  @type sync_item :: %{
          server_id: String.t(),
          read?: boolean(),
          received_at: DateTime.t() | nil
        }

  @callback connect(settings()) ::
              {:ok, conn()} | {:error, Manifold.Connectors.Provider.Error.t()}

  @callback provision(conn()) ::
              {:ok, conn(), %{policy_key: String.t()}}
              | {:error, Manifold.Connectors.Provider.Error.t()}

  @callback folder_sync(conn(), String.t()) ::
              {:ok, conn(), %{sync_key: String.t(), folders: [folder()]}}
              | {:error, Manifold.Connectors.Provider.Error.t()}

  @callback sync(conn(), map()) ::
              {:ok, conn(),
               %{
                 sync_key: String.t(),
                 adds: [sync_item()],
                 changes: [sync_item()],
                 deletes: [String.t()],
                 more_available?: boolean()
               }}
              | {:error, Manifold.Connectors.Provider.Error.t()}

  @callback change_read(conn(), map()) ::
              {:ok, conn(), %{sync_key: String.t()}}
              | {:error, Manifold.Connectors.Provider.Error.t()}

  @callback fetch_mime(conn(), String.t(), String.t()) ::
              {:ok, binary()} | {:error, Manifold.Connectors.Provider.Error.t()}

  @callback close(conn()) :: :ok
end
