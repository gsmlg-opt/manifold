defmodule Manifold.Connectors.SMTP.Transport do
  @moduledoc false

  @type conn :: term()
  @type settings :: %{
          host: String.t(),
          port: pos_integer(),
          tls_mode: String.t(),
          username: String.t(),
          password: String.t()
        }

  @callback connect(settings()) ::
              {:ok, conn()} | {:error, Manifold.Connectors.Provider.Error.t()}
  @callback quit(conn()) :: :ok
end
