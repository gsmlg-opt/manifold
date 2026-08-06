defmodule Manifold.Mail.CharsetTest do
  use ExUnit.Case, async: true

  alias Manifold.Mail.Charset

  # "你好" in GBK / CP936
  @nihao_gbk <<0xC4, 0xE3, 0xBA, 0xC3>>
  # "日报" in GB2312 / GBK
  @ribao_gbk <<0xC8, 0xD5, 0xB1, 0xA8>>

  test "decodes GBK and GB2312 aliases via CP936" do
    assert Charset.decode("gbk", @nihao_gbk) == "你好"
    assert Charset.decode("GB2312", @ribao_gbk) == "日报"
    assert Charset.decode("gb18030", @ribao_gbk) == "日报"
    assert Charset.decode("cp936", @nihao_gbk) == "你好"
    assert Charset.decode("x-gbk", @nihao_gbk) == "你好"
  end

  test "does not latin1-mojibake Chinese bytes" do
    refute Charset.decode("gb2312", @ribao_gbk) == "ÈÕ±¨"
    assert Charset.decode("gb2312", @ribao_gbk) == "日报"
  end

  test "keeps utf-8 and latin-1 paths working" do
    assert Charset.decode("utf-8", "Olá, 世界") == "Olá, 世界"
    assert Charset.decode("iso-8859-1", <<0xC0, 0xE9>>) == "Àé"
  end

  test "unknown charset still falls back without raising" do
    assert is_binary(Charset.decode("totally-unknown", @ribao_gbk))
  end
end
