defmodule Manifold.Mail.HtmlSanitizer do
  @moduledoc """
  Strict sanitizer for email HTML. Remote and inline images are blocked.
  """

  defmodule Scrubber do
    @moduledoc false
    use HtmlSanitizeEx

    allow_tag_with_these_attributes("a", ["title"]) do
      {"href", value} -> Manifold.Mail.HtmlSanitizer.safe_href_attribute(value)
    end

    for tag <-
          ~w(b blockquote br code del em h1 h2 h3 h4 h5 h6 hr i li ol p pre span strong table tbody td th thead tr u ul) do
      allow_tag_with_these_attributes(tag, [])
    end
  end

  @spec sanitize(String.t() | nil) :: String.t() | nil
  def sanitize(nil), do: nil

  def sanitize(html) when is_binary(html) do
    html
    |> remove_active_content()
    |> Scrubber.sanitize()
    |> force_safe_links()
  end

  @doc false
  def safe_href_attribute(value) when is_binary(value) do
    uri = URI.parse(String.trim(value))

    if uri.scheme in ["http", "https", "mailto"] do
      {"href", URI.to_string(uri)}
    end
  end

  def safe_href_attribute(_value), do: nil

  defp remove_active_content(html) do
    html
    |> HtmlSanitizeEx.Parser.parse()
    |> strip_active_nodes()
    |> HtmlSanitizeEx.Parser.to_html()
  end

  defp strip_active_nodes(nodes) when is_list(nodes),
    do: Enum.map(nodes, &strip_active_nodes/1)

  defp strip_active_nodes({tag, _attributes, _children})
       when tag in ~w(script style form input button textarea select option iframe object embed svg math meta link base) do
    ""
  end

  defp strip_active_nodes({tag, attributes, children}),
    do: {tag, attributes, strip_active_nodes(children)}

  defp strip_active_nodes({token, children}), do: {token, strip_active_nodes(children)}
  defp strip_active_nodes(other), do: other

  defp force_safe_links(html) do
    html
    |> HtmlSanitizeEx.Parser.parse()
    |> rewrite_links()
    |> HtmlSanitizeEx.Parser.to_html()
  end

  defp rewrite_links(nodes) when is_list(nodes), do: Enum.map(nodes, &rewrite_links/1)

  defp rewrite_links({"a", attributes, children}) do
    attributes =
      attributes
      |> List.keystore("target", 0, {"target", "_blank"})
      |> List.keystore("rel", 0, {"rel", "noopener noreferrer"})

    {"a", attributes, rewrite_links(children)}
  end

  defp rewrite_links({tag, attributes, children}),
    do: {tag, attributes, rewrite_links(children)}

  defp rewrite_links({token, children}), do: {token, rewrite_links(children)}
  defp rewrite_links(other), do: other
end
