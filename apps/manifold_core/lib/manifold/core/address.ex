defmodule Manifold.Core.Address do
  @moduledoc """
  SMTP envelope address parsing and canonicalization.

  Release 0.1 accepts ASCII envelope addresses only. Domains are normalized to
  lowercase and local parts are preserved separately from the case-insensitive
  canonical lookup form.
  """

  alias Manifold.Core.{Domain, Error}

  @max_address_bytes 254
  @max_local_part_bytes 64

  @type t :: %__MODULE__{
          original: String.t(),
          local_part: String.t(),
          canonical_local_part: String.t(),
          domain: String.t(),
          canonical: String.t()
        }

  defstruct [:original, :local_part, :canonical_local_part, :domain, :canonical]

  @spec parse(String.t(), Keyword.t()) :: {:ok, t()} | {:ok, :null_sender} | {:error, Error.t()}
  def parse(address, opts \\ [])

  def parse(address, opts) when is_binary(address) do
    if ascii?(address) do
      parse_ascii(String.trim(address), opts)
    else
      invalid("address must be ASCII")
    end
  end

  def parse(_address, _opts), do: invalid("address must be a string")

  defp parse_ascii(address, opts) do
    with {:ok, address} <- unwrap_path(address) do
      cond do
        address == "" and Keyword.get(opts, :allow_null_sender, false) ->
          {:ok, :null_sender}

        address == "" ->
          invalid("address is empty")

        String.contains?(address, ["\r", "\n", "\t", " "]) ->
          invalid("address contains whitespace")

        byte_size(address) > @max_address_bytes ->
          invalid("address exceeds SMTP length limit")

        true ->
          parse_parts(address)
      end
    end
  end

  @spec split_plus(String.t()) :: {String.t(), String.t() | nil}
  def split_plus(canonical_local_part) when is_binary(canonical_local_part) do
    case String.split(canonical_local_part, "+", parts: 2) do
      [base, tag] when base != "" and tag != "" -> {base, tag}
      _ -> {canonical_local_part, nil}
    end
  end

  defp parse_parts(address) do
    case String.split(address, "@", parts: 3) do
      [local_part, domain] when local_part != "" and domain != "" ->
        with :ok <- validate_local_part(local_part),
             {:ok, normalized_domain} <- Domain.normalize(domain) do
          canonical_local_part = String.downcase(local_part, :ascii)

          {:ok,
           %__MODULE__{
             original: address,
             local_part: local_part,
             canonical_local_part: canonical_local_part,
             domain: normalized_domain,
             canonical: canonical_local_part <> "@" <> normalized_domain
           }}
        end

      _ ->
        invalid("address must contain one local part and one domain")
    end
  end

  defp validate_local_part(local_part) do
    cond do
      byte_size(local_part) > @max_local_part_bytes ->
        invalid("local part exceeds SMTP length limit")

      String.starts_with?(local_part, ".") or String.ends_with?(local_part, ".") or
          String.contains?(local_part, "..") ->
        invalid("local part dot-atom syntax is invalid")

      Regex.match?(~r/^[A-Za-z0-9.!#$%&'*+\-\/=?^_`{|}~]+$/, local_part) ->
        :ok

      true ->
        invalid("local part syntax is invalid")
    end
  end

  defp unwrap_path("<" <> rest) do
    if String.ends_with?(rest, ">") do
      inner = binary_part(rest, 0, byte_size(rest) - 1)

      if String.contains?(inner, ["<", ">"]) do
        invalid("address path wrapper is malformed")
      else
        {:ok, inner}
      end
    else
      invalid("address path wrapper is malformed")
    end
  end

  defp unwrap_path(address) do
    if String.contains?(address, ["<", ">"]) do
      invalid("address path wrapper is malformed")
    else
      {:ok, address}
    end
  end

  defp invalid(message), do: {:error, Error.new(:permanent, :invalid_address, message)}

  defp ascii?(<<>>), do: true
  defp ascii?(<<byte, rest::binary>>) when byte in 1..127, do: ascii?(rest)
  defp ascii?(_value), do: false
end
