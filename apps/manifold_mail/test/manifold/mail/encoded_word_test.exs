defmodule Manifold.Mail.EncodedWordTest do
  use ExUnit.Case, async: true

  alias Manifold.Mail.EncodedWord

  test "decodes GB2312 base64 encoded-word" do
    assert EncodedWord.decode("=?GB2312?B?yNWxqA==?=") == "日报"
    assert EncodedWord.decode("=?gb2312?B?yNWxqA==?=") == "日报"
  end

  test "decodes adjacent encoded-words and quoted-printable" do
    assert EncodedWord.decode("=?utf-8?B?SGVsbG8=?= =?utf-8?B?IHdvcmxk?=") == "Hello world"
    assert EncodedWord.decode("=?utf-8?Q?Caf=C3=A9?=") == "Café"
  end

  test "leaves plain text unchanged" do
    assert EncodedWord.decode("plain subject") == "plain subject"
    assert EncodedWord.decode(nil) == nil
  end
end
