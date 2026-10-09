defmodule Manifold.Connectors.DAV.URL do
  @moduledoc false
  @hosts ~r/\A(?:contacts|caldav|p[0-9]+-contacts|p[0-9]+-caldav)\.icloud\.com\z/

  def validate(url) when is_binary(url) and byte_size(url) <= 4096 do
    uri = URI.parse(url)

    if uri.scheme == "https" and uri.port == 443 and is_binary(uri.host) and
         Regex.match?(@hosts, String.downcase(uri.host)) and is_nil(uri.userinfo) and
         is_nil(uri.fragment) and is_nil(uri.query) and not Regex.match?(~r/[\x00-\x20\\]/, url) do
      {:ok, URI.to_string(%{uri | host: String.downcase(uri.host)})}
    else
      {:error, :untrusted_url}
    end
  rescue
    _ -> {:error, :untrusted_url}
  end

  def validate(_), do: {:error, :untrusted_url}

  def resolve(base, href) when is_binary(href) do
    with {:ok, _} <- validate(base) do
      URI.merge(base, href) |> URI.to_string() |> validate()
    end
  rescue
    _ -> {:error, :untrusted_url}
  end

  def resolve(_, _), do: {:error, :untrusted_url}
end
