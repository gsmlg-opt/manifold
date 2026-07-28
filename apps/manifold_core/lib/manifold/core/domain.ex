defmodule Manifold.Core.Domain do
  @moduledoc """
  Domain normalization for ASCII SMTP envelope domains.
  """

  alias Manifold.Core.Error

  @type normalized :: String.t()

  @spec normalize(String.t()) :: {:ok, normalized()} | {:error, Error.t()}
  def normalize(domain) when is_binary(domain) do
    normalized =
      domain
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase(:ascii)

    cond do
      normalized == "" ->
        invalid("domain is empty")

      not ascii?(normalized) ->
        invalid("domain must be ASCII")

      String.contains?(normalized, "..") ->
        invalid("domain contains an empty label")

      not Regex.match?(
        ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/,
        normalized
      ) ->
        invalid("domain syntax is invalid")

      true ->
        {:ok, normalized}
    end
  end

  def normalize(_domain), do: invalid("domain must be a string")

  defp invalid(message), do: {:error, Error.new(:permanent, :invalid_domain, message)}

  defp ascii?(value), do: String.to_charlist(value) |> Enum.all?(&(&1 in 1..127))
end
