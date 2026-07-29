defmodule Manifold.SMTP.Acceptor do
  @moduledoc """
  Durable acceptance boundary used after SMTP DATA completes.
  """

  alias Manifold.Core.Error

  @callback accept_transport(binary(), map(), [struct() | map()]) ::
              {:ok, %{required(:ingest_id) => String.t()}} | {:error, Error.t() | term()}
end
