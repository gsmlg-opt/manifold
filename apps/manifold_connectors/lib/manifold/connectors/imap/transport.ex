defmodule Manifold.Connectors.IMAP.Transport do
  @moduledoc false

  @type conn :: term()
  @type settings :: %{
          host: String.t(),
          port: pos_integer(),
          tls_mode: String.t(),
          username: String.t(),
          password: String.t(),
          mailbox_path: String.t()
        }

  @callback connect(settings()) ::
              {:ok, conn()} | {:error, Manifold.Connectors.Provider.Error.t()}
  @callback select(conn(), String.t()) ::
              {:ok, %{uidvalidity: pos_integer(), uidnext: pos_integer() | nil}}
              | {:error, Manifold.Connectors.Provider.Error.t()}
  @callback uid_search(conn(), String.t()) ::
              {:ok, [pos_integer()]} | {:error, Manifold.Connectors.Provider.Error.t()}
  @callback uid_fetch_rfc822(conn(), pos_integer()) ::
              {:ok, binary()} | {:error, Manifold.Connectors.Provider.Error.t()}
  @callback logout(conn()) :: :ok
end
