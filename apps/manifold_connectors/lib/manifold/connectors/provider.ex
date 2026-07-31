defmodule Manifold.Connectors.Provider do
  @moduledoc """
  Normalized OAuth and mailbox synchronization boundary.
  """

  alias Manifold.Connectors.Provider.{
    DeviceCode,
    Error,
    Identity,
    Page,
    RawMessage,
    SyncCursor,
    Token
  }

  @callback exchange_code(String.t(), String.t(), String.t(), Keyword.t(), Keyword.t()) ::
              {:ok, Token.t()} | {:error, Error.t()}
  @callback request_device_code(Keyword.t(), Keyword.t()) ::
              {:ok, DeviceCode.t()} | {:error, Error.t()}
  @callback exchange_device_code(String.t(), Keyword.t(), Keyword.t()) ::
              {:ok, Token.t()}
              | {:pending, :authorization_pending}
              | {:pending, :slow_down, pos_integer()}
              | {:error, Error.t()}
  @callback refresh_token(String.t(), Keyword.t(), Keyword.t()) ::
              {:ok, Token.t()} | {:error, Error.t()}
  @callback identity(String.t(), Keyword.t(), Keyword.t()) ::
              {:ok, Identity.t()} | {:error, Error.t()}
  @callback initial_cursors(String.t(), Keyword.t(), Keyword.t()) ::
              {:ok, [SyncCursor.t()]} | {:error, Error.t()}
  @callback sync_page(String.t(), SyncCursor.t(), Keyword.t(), Keyword.t()) ::
              {:ok, Page.t()} | {:error, Error.t()}
  @callback fetch_raw(String.t(), String.t(), Keyword.t(), Keyword.t()) ::
              {:ok, RawMessage.t()} | {:error, Error.t()}
end

defmodule Manifold.Connectors.Provider.DeviceCode do
  @moduledoc false

  @enforce_keys [:device_code, :user_code, :verification_uri, :interval_seconds, :expires_at]
  defstruct [:verification_uri_complete | @enforce_keys]

  @type t :: %__MODULE__{
          device_code: String.t(),
          user_code: String.t(),
          verification_uri: String.t(),
          verification_uri_complete: String.t() | nil,
          interval_seconds: pos_integer(),
          expires_at: DateTime.t()
        }
end

defmodule Manifold.Connectors.Provider.Token do
  @moduledoc false

  @enforce_keys [:access_token, :expires_at, :scopes]
  defstruct [:refresh_token | @enforce_keys]

  @type t :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: DateTime.t(),
          scopes: [String.t()]
        }
end

defmodule Manifold.Connectors.Provider.Identity do
  @moduledoc false

  @enforce_keys [:id, :email_address]
  defstruct @enforce_keys

  @type t :: %__MODULE__{id: String.t(), email_address: String.t()}
end

defmodule Manifold.Connectors.Provider.SyncCursor do
  @moduledoc false

  @enforce_keys [:scope, :phase]
  defstruct [
    :bootstrap_cursor,
    :page_cursor,
    :committed_cursor,
    metadata: %{},
    scope: nil,
    phase: nil
  ]

  @type t :: %__MODULE__{
          scope: String.t(),
          phase: String.t(),
          bootstrap_cursor: String.t() | nil,
          page_cursor: String.t() | nil,
          committed_cursor: String.t() | nil,
          metadata: map()
        }
end

defmodule Manifold.Connectors.Provider.RemoteMessage do
  @moduledoc false

  @enforce_keys [:id]
  defstruct [
    :thread_id,
    :received_at,
    :folder_id,
    :folder_kind,
    :tombstone_kind,
    id: nil,
    labels: [],
    read?: false,
    starred?: false,
    deleted?: false
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          thread_id: String.t() | nil,
          received_at: DateTime.t() | nil,
          folder_id: String.t() | nil,
          folder_kind: String.t() | nil,
          tombstone_kind: :membership | :message | nil,
          labels: [String.t()],
          read?: boolean(),
          starred?: boolean(),
          deleted?: boolean()
        }
end

defmodule Manifold.Connectors.Provider.Page do
  @moduledoc false

  alias Manifold.Connectors.Provider.{RemoteMessage, SyncCursor}

  @enforce_keys [:cursor]
  defstruct cursor: nil, messages: [], discovered_cursors: []

  @type t :: %__MODULE__{
          cursor: SyncCursor.t(),
          messages: [RemoteMessage.t()],
          discovered_cursors: [SyncCursor.t()]
        }
end

defmodule Manifold.Connectors.Provider.RawMessage do
  @moduledoc false

  @enforce_keys [:bytes]
  defstruct [
    :received_at,
    :thread_id,
    :folder_id,
    :folder_kind,
    bytes: nil,
    labels: [],
    read?: false,
    starred?: false
  ]

  @type t :: %__MODULE__{
          bytes: binary(),
          received_at: DateTime.t() | nil,
          thread_id: String.t() | nil,
          folder_id: String.t() | nil,
          folder_kind: String.t() | nil,
          labels: [String.t()],
          read?: boolean(),
          starred?: boolean()
        }
end

defmodule Manifold.Connectors.Provider.Error do
  @moduledoc false

  @enforce_keys [:class, :code, :message]
  defstruct [:retry_after_seconds | @enforce_keys]

  @type t :: %__MODULE__{
          class: :temporary | :permanent | :reconnect,
          code: atom(),
          message: String.t(),
          retry_after_seconds: pos_integer() | nil
        }
end
