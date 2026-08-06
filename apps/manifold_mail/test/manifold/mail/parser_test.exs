defmodule Manifold.Mail.ParserTest do
  use ExUnit.Case, async: true

  alias Manifold.Mail.Parser

  test "parses plain text and preserves ordered repeated headers" do
    raw =
      message("""
      From: Alice Example <alice@example.net>
      To: Inbox <inbox@example.test>
      Subject: Hello
      Message-ID: <plain-1@example.net>
      X-Trace: first
      X-Trace: second
      Content-Type: text/plain; charset=utf-8

      Hello from plain text.
      """)

    assert {:ok, parsed} = Parser.parse(raw)
    assert parsed.subject == "Hello"
    assert parsed.rfc_message_id == "<plain-1@example.net>"
    assert parsed.from == [%{name: "Alice Example", address: "alice@example.net"}]
    assert parsed.to == [%{name: "Inbox", address: "inbox@example.test"}]
    assert parsed.text_body == "Hello from plain text."
    assert parsed.html_body == nil

    assert Enum.map(parsed.headers, &{&1.position, &1.normalized_name, &1.value}) ==
             [
               {0, "from", "Alice Example <alice@example.net>"},
               {1, "to", "Inbox <inbox@example.test>"},
               {2, "subject", "Hello"},
               {3, "message-id", "<plain-1@example.net>"},
               {4, "x-trace", "first"},
               {5, "x-trace", "second"},
               {6, "content-type", "text/plain; charset=utf-8"}
             ]
  end

  test "parses Date header strings into sent_at" do
    raw =
      message("""
      From: Alice Example <alice@example.net>
      To: Inbox <inbox@example.test>
      Subject: Dated
      Date: Mon, 27 Jan 2020 04:03:43 +0800
      Message-ID: <dated-1@example.net>
      Content-Type: text/plain; charset=utf-8

      Hello.
      """)

    assert {:ok, parsed} = Parser.parse(raw)
    assert parsed.sent_at == ~U[2020-01-26 20:03:43.000000Z]
  end

  test "parse_datetime accepts RFC2822 strings" do
    assert Parser.parse_datetime("Mon, 27 Jan 2020 04:03:43 +0800") ==
             ~U[2020-01-26 20:03:43.000000Z]
  end

  test "selects multipart alternatives and extracts an attachment" do
    raw =
      message("""
      From: sender@example.net
      To: inbox@example.test
      Subject: Multipart
      Message-ID: <multipart-1@example.net>
      Content-Type: multipart/mixed; boundary=outer

      --outer
      Content-Type: multipart/alternative; boundary=alternative

      --alternative
      Content-Type: text/plain; charset=utf-8

      Plain body
      --alternative
      Content-Type: text/html; charset=utf-8

      <p>HTML body</p>
      --alternative--
      --outer
      Content-Type: application/octet-stream; name="../report.bin"
      Content-Disposition: attachment; filename="../report.bin"
      Content-Transfer-Encoding: base64

      YXR0YWNobWVudA==
      --outer--
      """)

    assert {:ok, parsed} = Parser.parse(raw)
    assert parsed.text_body == "Plain body"
    assert parsed.html_body == "<p>HTML body</p>"

    assert [
             %{
               part_path: "2",
               filename: "../report.bin",
               media_type: "application/octet-stream",
               disposition: "attachment",
               bytes: "attachment",
               size: 10,
               sha256: sha256
             }
           ] = parsed.attachments

    assert sha256 == :crypto.hash(:sha256, "attachment") |> Base.encode16(case: :lower)
  end

  test "parses nested related content and identifies inline attachments" do
    raw =
      message("""
      From: sender@example.net
      To: inbox@example.test
      Subject: Related
      Content-Type: multipart/related; boundary=related

      --related
      Content-Type: text/html; charset=utf-8

      <p><img src="cid:logo@example.net"></p>
      --related
      Content-Type: image/png; name=logo.png
      Content-Disposition: inline; filename=logo.png
      Content-ID: <logo@example.net>
      Content-Transfer-Encoding: base64

      iVBORw0KGgo=
      --related--
      """)

    assert {:ok, parsed} = Parser.parse(raw)
    assert parsed.html_body =~ "cid:logo@example.net"

    assert [
             %{
               content_id: "<logo@example.net>",
               disposition: "inline",
               filename: "logo.png",
               media_type: "image/png"
             }
           ] = parsed.attachments
  end

  test "keeps the primary mixed body when a later branch contains competing alternatives" do
    raw =
      message("""
      From: sender@example.net
      To: inbox@example.test
      Subject: Competing mixed branches
      Content-Type: multipart/mixed; boundary=outer

      --outer
      Content-Type: multipart/alternative; boundary=primary

      --primary
      Content-Type: text/plain; charset=utf-8

      Primary plain body
      --primary
      Content-Type: text/html; charset=utf-8

      <p>Primary HTML body</p>
      --primary--
      --outer
      Content-Type: multipart/alternative; boundary=forwarded
      Content-Disposition: attachment

      --forwarded
      Content-Type: text/plain; charset=utf-8

      Forwarded plain body
      --forwarded
      Content-Type: text/html; charset=utf-8

      <p>Forwarded HTML body</p>
      --forwarded--
      --outer--
      """)

    assert {:ok, parsed} = Parser.parse(raw)
    assert parsed.text_body == "Primary plain body"
    assert parsed.html_body == "<p>Primary HTML body</p>"
  end

  test "uses the declared multipart related root instead of a competing sibling" do
    raw =
      message("""
      From: sender@example.net
      To: inbox@example.test
      Subject: Related root
      Content-Type: multipart/related; boundary=related; start="<root@example.net>"

      --related
      Content-Type: text/plain; charset=utf-8
      Content-ID: <resource@example.net>

      Unrelated text resource
      --related
      Content-Type: multipart/alternative; boundary=primary
      Content-ID: <root@example.net>

      --primary
      Content-Type: text/plain; charset=utf-8

      Related root plain body
      --primary
      Content-Type: text/html; charset=utf-8

      <p>Related root HTML body</p>
      --primary--
      --related--
      """)

    assert {:ok, parsed} = Parser.parse(raw)
    assert parsed.text_body == "Related root plain body"
    assert parsed.html_body == "<p>Related root HTML body</p>"
  end

  test "preserves sender and bcc address collections" do
    raw =
      message("""
      From: Author <author@example.net>
      Sender: Submission Agent <agent@example.net>
      To: inbox@example.test
      Bcc: Hidden One <hidden-one@example.test>, hidden-two@example.test
      Subject: Address kinds
      Content-Type: text/plain

      Body
      """)

    assert {:ok, parsed} = Parser.parse(raw)

    assert parsed.sender == [
             %{name: "Submission Agent", address: "agent@example.net"}
           ]

    assert parsed.bcc == [
             %{name: "Hidden One", address: "hidden-one@example.test"},
             %{name: nil, address: "hidden-two@example.test"}
           ]
  end

  test "unfolds long headers and accepts missing message id and 8-bit body" do
    raw =
      message("""
      From: sender@example.net
      To: inbox@example.test
      Subject: Long
      X-Long: first
       second
      Content-Type: text/plain; charset=utf-8
      Content-Transfer-Encoding: 8bit

      Olá, 世界
      """)

    assert {:ok, parsed} = Parser.parse(raw)
    assert parsed.rfc_message_id == nil
    assert parsed.text_body == "Olá, 世界"
    assert Enum.find(parsed.headers, &(&1.normalized_name == "x-long")).value == "first second"
  end

  test "decodes GB2312 encoded-word subject and base64 GBK body" do
    # Subject "日报" as =?gb2312?B?yNWxqA==?=
    # Body "你好" GBK bytes C4 E3 BA C3, base64 xOO6ww==
    raw =
      message("""
      From: =?gb2312?B?uN/KwMP3?= <sender@example.test>
      To: inbox@example.test
      Subject: =?gb2312?B?yNWxqA==?=
      Content-Type: text/plain; charset=gb2312
      Content-Transfer-Encoding: base64

      xOO6ww==
      """)

    assert {:ok, parsed} = Parser.parse(raw)
    assert parsed.subject == "日报"
    assert parsed.text_body == "你好"
    assert hd(parsed.from).name == "高世明"
  end

  test "decodes unlabeled GBK subject and from display name" do
    # Tencent-style 8-bit headers without RFC 2047 encoded-words.
    subject_gbk =
      <<0xCC, 0xDA, 0xD1, 0xB6, 0xD3, 0xF2, 0xC3, 0xFB, 0xD3, 0xCA, 0xCF, 0xE4, 0xA3, 0xBA, 0xD3,
        0xF2, 0xC3, 0xFB, 0xD3, 0xCA, 0xCF, 0xE4, 0xD5, 0xCB, 0xBA, 0xC5, " org@gs">>

    from_name_gbk = <<0xCC, 0xDA, 0xD1, 0xB6>>
    body_gbk = <<0xC4, 0xE3, 0xBA, 0xC3>>

    raw =
      "From: " <>
        from_name_gbk <>
        " <noreply@exmail.qq.com>\r\n" <>
        "To: inbox@example.test\r\n" <>
        "Subject: " <>
        subject_gbk <>
        "\r\n" <>
        "Content-Type: text/plain; charset=gbk\r\n" <>
        "Content-Transfer-Encoding: 8bit\r\n\r\n" <>
        body_gbk <>
        "\r\n"

    assert {:ok, parsed} = Parser.parse(raw)
    assert parsed.subject == "腾讯域名邮箱：域名邮箱账号 org@gs"
    assert hd(parsed.from).name == "腾讯"
    assert hd(parsed.from).address == "noreply@exmail.qq.com"
    assert parsed.text_body == "你好"
    refute String.starts_with?(parsed.subject, "ÌÚÑ¶")
  end

  test "decodes quoted-printable UTF-8 body without mojibake" do
    raw =
      message("""
      From: sender@example.net
      To: inbox@example.test
      Subject: =?UTF-8?Q?=E4=B8=96=E7=95=8C?=
      Content-Type: text/plain; charset=utf-8
      Content-Transfer-Encoding: quoted-printable

      Ol=C3=A1, =E4=B8=96=E7=95=8C
      """)

    assert {:ok, parsed} = Parser.parse(raw)
    assert parsed.subject == "世界"
    assert parsed.text_body == "Olá, 世界"
  end

  test "returns classified failures for malformed messages and enforced limits" do
    assert {:error, %{reason: :invalid_headers}} = Parser.parse("not-a-header\r\n\r\nbody")

    raw = message("Subject: large\n\n123456")
    assert {:error, %{reason: :raw_too_large}} = Parser.parse(raw, max_raw_bytes: 5)

    multipart =
      message("""
      Subject: many
      Content-Type: multipart/mixed; boundary=many

      --many
      Content-Type: text/plain

      one
      --many
      Content-Type: text/plain

      two
      --many--
      """)

    assert {:error, %{reason: :too_many_parts}} = Parser.parse(multipart, max_parts: 1)

    nested =
      message("""
      Subject: nested
      Content-Type: multipart/mixed; boundary=outer

      --outer
      Content-Type: multipart/alternative; boundary=inner

      --inner
      Content-Type: text/plain

      body
      --inner--
      --outer--
      """)

    assert {:error, %{reason: :mime_too_deep}} =
             Parser.parse(nested, max_mime_depth: 1)

    decoded = message("Subject: decoded\n\n123456")

    assert {:error, %{reason: :decoded_content_too_large}} =
             Parser.parse(decoded, max_decoded_bytes: 5)

    attachment =
      message("""
      Subject: attachment
      Content-Type: multipart/mixed; boundary=attachment

      --attachment
      Content-Type: application/octet-stream
      Content-Disposition: attachment; filename=data.bin
      Content-Transfer-Encoding: base64

      YXR0YWNobWVudA==
      --attachment--
      """)

    assert {:error, %{reason: :attachment_too_large}} =
             Parser.parse(attachment, max_attachment_bytes: 5)
  end

  defp message(indented) do
    indented
    |> String.trim()
    |> String.replace("\n      ", "\n")
    |> String.replace("\n", "\r\n")
    |> Kernel.<>("\r\n")
  end
end
