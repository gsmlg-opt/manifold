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

  test "round-trips Provision with Settings DeviceInformation code page" do
    doc =
      {14, "Provision",
       [
         {18, "DeviceInformation",
          [
            {18, "Set",
             [
               {18, "Model", ["iPhone"]},
               {18, "UserAgent", ["Apple-iPhone15C1/2202.75"]}
             ]}
          ]},
         {14, "Policies",
          [
            {14, "Policy", [{14, "PolicyType", ["MS-EAS-Provisioning-WBXML"]}]}
          ]}
       ]}

    assert {:ok, decoded} = WBXML.decode(WBXML.encode(doc))
    assert WBXML.text(WBXML.find(decoded, "Model")) == "iPhone"
    assert WBXML.find(decoded, "DeviceInformation")
    assert WBXML.text(WBXML.find(decoded, "PolicyType")) == "MS-EAS-Provisioning-WBXML"
  end

  test "decode skips unknown provision policy tags" do
    # Minimal Provision response with DevicePasswordEnabled (0x0E) under EASProvisionDoc.
    # Header 03 01 6A 00, SWITCH_PAGE 14, then nested tokens.
    binary =
      <<0x03, 0x01, 0x6A, 0x00, 0x00, 0x0E, 0x45, 0x4B, 0x03, "1", 0x00, 0x01, 0x46, 0x47, 0x4A,
        0x4D, 0x4E, 0x03, "0", 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01>>

    assert {:ok, root} = WBXML.decode(binary)
    assert elem(root, 1) == "Provision"
    assert WBXML.text(WBXML.find(root, "Status")) == "1"
    assert WBXML.text(WBXML.find(root, "DevicePasswordEnabled")) == "0"
  end

  test "decode tolerates completely unknown tokens" do
    # Page 0 token 0x3A is unused in our table; treat as _u58 and continue.
    binary = <<0x03, 0x01, 0x6A, 0x00, 0x45, 0x7A, 0x03, "x", 0x00, 0x01, 0x01>>
    assert {:ok, root} = WBXML.decode(binary)
    assert elem(root, 1) == "Sync"
    assert WBXML.find(root, "_u58")
  end
end
