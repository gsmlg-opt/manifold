defmodule Manifold.Mail.Charset do
  @moduledoc false

  @windows_1252 "VENDORS/MICSFT/WINDOWS/CP1252"

  @spec decode(String.t(), binary()) :: String.t()
  def decode(charset, binary) when is_binary(charset) and is_binary(binary) do
    case String.downcase(String.trim(charset, " \"'")) do
      value when value in ["utf-8", "utf8"] ->
        ensure_utf8(binary)

      value when value in ["us-ascii", "ascii"] ->
        convert(binary, :ascii)

      value when value in ["iso-8859-1", "iso8859-1", "latin1", "latin-1"] ->
        convert(binary, :iso_8859_1)

      value when value in ["windows-1252", "cp1252", "windows1252"] ->
        convert(binary, @windows_1252)

      _unknown ->
        ensure_utf8(binary)
    end
  end

  defp convert(binary, encoding) do
    case Codepagex.to_string(binary, encoding, Codepagex.use_utf_replacement()) do
      {:ok, converted, _replacements} -> converted
      {:error, _reason} -> ensure_utf8(binary)
    end
  end

  defp ensure_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      :unicode.characters_to_binary(binary, :latin1, :utf8)
    end
  end
end
