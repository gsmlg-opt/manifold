defmodule Manifold.Core.HTTPClient.Response do
  @moduledoc "HTTP response with ordered values for each case-insensitive header."
  defstruct status: nil, headers: %{}, body: nil, trailers: %{}, private: %{}

  def get_header(%__MODULE__{headers: headers}, name),
    do: Map.get(headers, String.downcase(name), [])
end
