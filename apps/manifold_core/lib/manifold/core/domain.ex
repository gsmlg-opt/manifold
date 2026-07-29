defmodule Manifold.Core.Domain do
  @moduledoc """
  Domain normalization for ASCII SMTP envelope domains.
  """

  alias Manifold.Core.Error

  @max_domain_bytes 255

  @type normalized :: String.t()

  @spec normalize(String.t()) :: {:ok, normalized()} | {:error, Error.t()}
  def normalize(domain) when is_binary(domain) do
    if ascii?(domain) do
      normalize_ascii(domain)
    else
      invalid("domain must be ASCII")
    end
  end

  def normalize(_domain), do: invalid("domain must be a string")

  defp normalize_ascii(domain) do
    normalized =
      domain
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase(:ascii)

    cond do
      normalized == "" ->
        invalid("domain is empty")

      byte_size(normalized) > @max_domain_bytes ->
        invalid("domain exceeds SMTP length limit")

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

  defp invalid(message), do: {:error, Error.new(:permanent, :invalid_domain, message)}

  defp ascii?(<<>>), do: true
  defp ascii?(<<byte, rest::binary>>) when byte in 1..127, do: ascii?(rest)
  defp ascii?(_value), do: false
end
