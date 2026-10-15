defmodule Manifold.Core.HTTPClient.TransportError do
  @moduledoc "Secret-safe HTTP failure. Only proven connection failures are pre-transmission."
  defexception reason: :transport_failure, phase: :unknown
  def message(_error), do: "HTTP request failed"
end
