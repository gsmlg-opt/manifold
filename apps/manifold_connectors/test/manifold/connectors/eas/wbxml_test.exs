defmodule Manifold.Connectors.EAS.WBXMLTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.EAS.WBXML

  test "round-trips FolderSync document" do
    doc =
      {5, "FolderSync",
       [
         {5, "SyncKey", ["0"]}
       ]}

    binary = WBXML.encode(doc)
    assert <<0x03, 0x01, 0x6A, 0x00, _rest::binary>> = binary
    assert {:ok, decoded} = WBXML.decode(binary)
    assert WBXML.text(WBXML.child(decoded, "SyncKey")) == "0"
  end

  test "round-trips nested Sync with BodyPreference code page switch" do
    doc =
      {0, "Sync",
       [
         {0, "Collections",
          [
            {0, "Collection",
             [
               {0, "SyncKey", ["1"]},
               {0, "CollectionId", ["12"]},
               {0, "Options",
                [
                  {17, "BodyPreference", [{17, "Type", ["4"]}]}
                ]}
             ]}
          ]}
       ]}

    assert {:ok, decoded} = WBXML.decode(WBXML.encode(doc))
    assert WBXML.text(WBXML.find(decoded, "CollectionId")) == "12"
    assert WBXML.text(WBXML.find(decoded, "Type")) == "4"
  end

  test "decode rejects invalid header" do
    assert {:error, :invalid_wbxml} = WBXML.decode(<<"not-wbxml">>)
  end
end
