defmodule Manifold.Connectors.Schema.EasSupportTest do
  use Manifold.DataCase, async: true

  alias Manifold.Connectors.Schema.{EasSettings, ReceiveMethod}

  test "external account accepts eas provider" do
    changeset =
      ReceiveMethod.changeset(%ReceiveMethod{}, %{
        account_id: Ecto.UUID.generate(),
        kind: "eas",
        provider_account_id: "eas:user@example.com",
        email_address: "user@example.com",
        status: "connected",
        enabled: true,
        sync_enabled: true,
        granted_scopes: []
      })

    assert changeset.valid?
    assert "eas" in ReceiveMethod.implemented_kinds()
    refute "eas" in ReceiveMethod.placeholder_kinds()
  end

  test "eas settings validate required fields and port" do
    good =
      EasSettings.changeset(%EasSettings{}, %{
        external_account_id: Ecto.UUID.generate(),
        host: "mail.example.com",
        port: 443,
        path: "/Microsoft-Server-ActiveSync",
        domain: "CORP",
        username: "user",
        device_id: String.duplicate("a", 16),
        device_type: "iPhone",
        protocol_version: "14.1",
        policy_key: "12345"
      })

    assert good.valid?
    assert Ecto.Changeset.get_change(good, :domain) == "CORP"

    blank_domain =
      EasSettings.changeset(%EasSettings{}, %{
        external_account_id: Ecto.UUID.generate(),
        host: "mail.example.com",
        port: 443,
        path: "/Microsoft-Server-ActiveSync",
        domain: "  ",
        username: "user",
        device_id: "abc123",
        device_type: "iPhone",
        protocol_version: "14.1"
      })

    assert blank_domain.valid?
    assert Ecto.Changeset.get_change(blank_domain, :domain) == nil

    bad =
      EasSettings.changeset(%EasSettings{}, %{
        external_account_id: Ecto.UUID.generate(),
        host: "mail.example.com",
        port: 0,
        path: "/Microsoft-Server-ActiveSync",
        username: "user",
        device_id: "abc",
        device_type: "iPhone",
        protocol_version: "14.1"
      })

    refute bad.valid?
  end
end
