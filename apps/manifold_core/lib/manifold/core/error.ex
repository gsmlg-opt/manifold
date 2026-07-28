defmodule Manifold.Core.Error do
  @moduledoc """
  Classified expected errors shared across Manifold applications.
  """

  @type class :: :permanent | :temporary | :capacity
  @type reason ::
          :invalid_address
          | :invalid_domain
          | :unknown_recipient
          | :disabled_recipient
          | :database_unavailable
          | :spool_failed
          | :insufficient_spool_capacity
          | :message_too_large
          | :acceptance_failed
          | :object_store_failed
          | :invalid_state_transition
          | atom()

  @type t :: %__MODULE__{
          class: class(),
          reason: reason(),
          message: String.t(),
          details: map()
        }

  defstruct [:class, :reason, :message, details: %{}]

  @spec new(class(), reason(), String.t(), map()) :: t()
  def new(class, reason, message, details \\ %{}) do
    %__MODULE__{class: class, reason: reason, message: message, details: details}
  end
end
