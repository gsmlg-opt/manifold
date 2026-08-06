defmodule Manifold.Mail.Charset do
  @moduledoc false

  @windows_1252 "VENDORS/MICSFT/WINDOWS/CP1252"
  @cp936 "VENDORS/MICSFT/WINDOWS/CP936"

  @spec decode(String.t(), binary()) :: String.t()
  def decode(charset, binary) when is_binary(charset) and is_binary(binary) do
    case normalize(charset) do
      value when value in ["utf-8", "utf8"] ->
        ensure_utf8(binary)

      value when value in ["us-ascii", "ascii"] ->
        convert(binary, :ascii)

      value when value in ["iso-8859-1", "iso8859-1", "latin1", "latin-1"] ->
        convert(binary, :iso_8859_1)

      value when value in ["windows-1252", "cp1252", "windows1252"] ->
        convert(binary, @windows_1252)

      value
      when value in [
             "gb2312",
             "gbk",
             "gb18030",
             "cp936",
             "windows-936",
             "windows936",
             "x-gbk",
             "x-gb2312",
             "csgb2312",
             "chinese",
             "cn-gb",
             "hz-gb-2312"
           ] ->
        # CP936 covers GB2312/GBK; labeled GB18030 mail is almost always GBK-range.
        convert(binary, @cp936)

      _unknown ->
        ensure_utf8(binary)
    end
  end

  defp normalize(charset) do
    charset
    |> String.trim()
    |> String.trim(" \"'")
    |> String.downcase()
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
