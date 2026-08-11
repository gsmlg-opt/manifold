defmodule Manifold.Connectors.SubmissionMethod do
  @moduledoc """
  Runtime submission identity and credential material checked out from Connectors.

  This value is intentionally not persisted. Its credential is redacted from inspection.
  """

  @enforce_keys [:id, :account_id, :kind, :email_address]
  defstruct [:id, :account_id, :kind, :email_address, :credential, :config]

  @type credential :: {:oauth, String.t()} | {:password, String.t()} | nil

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          kind: String.t(),
          email_address: String.t(),
          credential: credential(),
          config: keyword() | map() | nil
        }
end

defimpl Inspect, for: Manifold.Connectors.SubmissionMethod do
  import Inspect.Algebra

  def inspect(method, opts) do
    fields =
      method
      |> Map.from_struct()
      |> Map.put(:credential, redact(method.credential))

    concat(["#Manifold.Connectors.SubmissionMethod<", to_doc(fields, opts), ">"])
  end

  defp redact(nil), do: nil
  defp redact(_credential), do: :redacted
end
