defmodule Manifold.SMTP.Resolver do
  @moduledoc """
  Recipient-resolution boundary used by the transport session.

  Implementations return frozen route data; the SMTP application does not
  inspect persistence owned by the implementation.
  """

  alias Manifold.Core.Error

  @callback resolve_recipient(String.t()) :: {:ok, struct() | map()} | {:error, Error.t()}
  @callback begin_transaction() :: {:ok, term()} | {:error, Error.t() | term()}
  @callback resolve_recipient(String.t(), term()) ::
              {:ok, struct() | map()} | {:error, Error.t()}

  @optional_callbacks begin_transaction: 0, resolve_recipient: 1, resolve_recipient: 2
end
