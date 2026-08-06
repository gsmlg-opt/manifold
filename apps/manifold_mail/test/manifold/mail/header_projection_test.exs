defmodule Manifold.Mail.HeaderProjectionTest do
  use ExUnit.Case, async: true

  alias Manifold.Mail.HeaderProjection

  # "腾讯域名邮箱：域名邮箱账号 org@gs" in GBK
  @tencent_subject_gbk <<0xCC, 0xDA, 0xD1, 0xB6, 0xD3, 0xF2, 0xC3, 0xFB, 0xD3, 0xCA, 0xCF, 0xE4,
                         0xA3, 0xBA, 0xD3, 0xF2, 0xC3, 0xFB, 0xD3, 0xCA, 0xCF, 0xE4, 0xD5, 0xCB,
                         0xBA, 0xC5, " org@gs">>

  test "decodes unlabeled GBK subject bytes without latin1 mojibake" do
    raw =
      "From: sender@example.test\r\n" <>
        "Subject: " <>
        @tencent_subject_gbk <>
        "\r\n" <>
        "Content-Type: text/plain; charset=gbk\r\n\r\n" <>
        "body\r\n"

    assert {:ok, headers} =
             HeaderProjection.parse(raw, max_header_bytes: 100_000, max_headers: 100)

    subject = Enum.find(headers, &(&1.normalized_name == "subject")).value
    assert subject == "腾讯域名邮箱：域名邮箱账号 org@gs"
    refute String.starts_with?(subject, "ÌÚÑ¶")
  end
end
