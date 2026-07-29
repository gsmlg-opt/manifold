defmodule Manifold.Mail.HtmlSanitizerTest do
  use ExUnit.Case, async: true

  alias Manifold.Mail.HtmlSanitizer

  test "removes active content, event attributes, styles, and images" do
    html =
      """
      <style>body { background: url(https://tracker.test/pixel) }</style>
      <script>alert(1)</script>
      <form action="https://attacker.test"><input name="secret"></form>
      <svg onload="alert(1)"><circle></circle></svg>
      <p onclick="alert(1)" style="color:red">Safe text</p>
      <img src="https://tracker.test/pixel" onerror="alert(1)">
      """

    sanitized = HtmlSanitizer.sanitize(html)

    assert sanitized =~ "<p>Safe text</p>"
    refute sanitized =~ "<script"
    refute sanitized =~ "<style"
    refute sanitized =~ "<form"
    refute sanitized =~ "<input"
    refute sanitized =~ "<svg"
    refute sanitized =~ "<img"
    refute sanitized =~ "onclick"
    refute sanitized =~ "tracker.test"
  end

  test "keeps only explicit safe link schemes and forces defensive attributes" do
    html =
      """
      <a href="https://example.test/path">HTTPS</a>
      <a href="mailto:user@example.test">Mail</a>
      <a href="javascript:alert(1)">Bad</a>
      <a href="/admin">Relative</a>
      """

    sanitized = HtmlSanitizer.sanitize(html)

    assert sanitized =~ ~s(href="https://example.test/path")
    assert sanitized =~ ~s(href="mailto:user@example.test")
    assert sanitized =~ ~s(target="_blank")
    assert sanitized =~ ~s(rel="noopener noreferrer")
    refute sanitized =~ "javascript:"
    refute sanitized =~ ~s(href="/admin")
  end
end
