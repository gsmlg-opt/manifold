defmodule Manifold.Core.ID do
  @moduledoc """
  Trusted internal identifier generation.
  """

  @type t :: String.t()

  @spec generate() :: t()
  def generate do
    <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
      e::binary-size(6)>> =
      :crypto.strong_rand_bytes(16)

    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end

  @spec safe_path_id?(String.t()) :: boolean()
  def safe_path_id?(id) when is_binary(id), do: Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, id)
  def safe_path_id?(_id), do: false
end
