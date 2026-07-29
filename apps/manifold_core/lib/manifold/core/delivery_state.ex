defmodule Manifold.Core.DeliveryState do
  @moduledoc """
  Validates delivery lifecycle transitions.
  """

  alias Manifold.Core.Error

  @raw_transitions %{
    "spooled" => ~w(archived failed missing_spool),
    "archived" => [],
    "failed" => ~w(spooled),
    "missing_spool" => ~w(spooled)
  }

  @processing_transitions %{
    "accepted" => ~w(archiving archived failed),
    "archiving" => ~w(archived failed),
    "archived" => [],
    "failed" => ~w(accepted archiving)
  }

  @spec validate_raw_transition(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def validate_raw_transition(from, to), do: validate(@raw_transitions, from, to)

  @spec validate_processing_transition(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def validate_processing_transition(from, to), do: validate(@processing_transitions, from, to)

  defp validate(transitions, from, to) do
    allowed = Map.get(transitions, from, [])

    if to in allowed or from == to do
      :ok
    else
      {:error,
       Error.new(:permanent, :invalid_state_transition, "invalid delivery state transition", %{
         from: from,
         to: to
       })}
    end
  end
end
