defmodule ManifoldAPI.Error do
  @moduledoc """
  Maps `Manifold.Core.Error` values to HTTP status codes and JSON payloads.
  """

  alias Manifold.Core.Error

  @spec status(Error.t()) :: pos_integer()
  def status(%Error{class: class}) when class in [:temporary, :capacity], do: 503

  def status(%Error{reason: :not_found}), do: 404

  def status(%Error{reason: reason}) do
    if reason |> Atom.to_string() |> String.starts_with?("invalid") do
      422
    else
      400
    end
  end

  @spec to_map(Error.t()) :: map()
  def to_map(%Error{} = error) do
    %{
      error: %{
        reason: to_string(error.reason),
        message: error.message,
        class: to_string(error.class)
      }
    }
  end
end
