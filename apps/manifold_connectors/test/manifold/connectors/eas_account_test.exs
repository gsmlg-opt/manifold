defmodule Manifold.Connectors.EasAccountTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.EAS.Fake
  alias Manifold.Connectors.Schema.{Credential, EasSettings, ReceiveMethod}
  alias Manifold.Repo

  setup do
    previous_transport = Application.get_env(:manifold_connectors, :eas_transport)
    previous_fake = Application.get_env(:manifold_connectors, :eas_fake)

    Application.put_env(:manifold_connectors, :eas_transport, Fake)

    Application.put_env(:manifold_connectors, :eas_fake, %{
      password_expected: "secret",
      messages: []
    })

    on_exit(fn ->
      restore_env(:eas_transport, previous_transport)
      restore_env(:eas_fake, previous_fake)
    end)

    :ok
  end

  test "create_eas_account stores settings and password credential" do
    assert {:ok, account} =
             Connectors.create_eas_account(%{
               email_address: "reader@eas.example",
               username: "DOMAIN\\reader",
               password: "secret",
               host: "mail.eas.example",
               port: 443
             })

    assert account.kind == "eas"
    assert account.email_address == "reader@eas.example"
    assert account.provider_account_id == "eas:reader@eas.example"
    assert account.enabled

    mailbox = Accounts.get_account!(account.account_id) |> Repo.preload(:domain)
    assert mailbox.domain.normalized_domain == "eas.example"

    credential = Repo.get_by!(Credential, external_account_id: account.id)
    assert credential.secret_kind == "password"
    assert is_binary(credential.password_ciphertext)

    settings = Repo.get_by!(EasSettings, external_account_id: account.id)
    assert settings.host == "mail.eas.example"
    assert settings.port == 443
    assert settings.path == "/Microsoft-Server-ActiveSync"
    assert settings.username == "DOMAIN\\reader"
    assert settings.policy_key == "12345"
    assert byte_size(settings.device_id) == 32
    assert settings.device_id =~ ~r/^[0-9a-f]{32}$/
    assert settings.domain == nil
  end

  test "create_eas_account stores optional domain" do
    assert {:ok, account} =
             Connectors.create_eas_account(%{
               email_address: "reader@eas-domain.example",
               username: "reader",
               domain: "CORP",
               password: "secret",
               host: "mail.eas.example",
               port: 443
             })

    settings = Repo.get_by!(EasSettings, external_account_id: account.id)
    assert settings.domain == "CORP"
    assert settings.username == "reader"
  end

  test "create_eas_account trims host and username whitespace" do
    assert {:ok, account} =
             Connectors.create_eas_account(%{
               email_address: "  padded@eas.example ",
               username: "  padded@eas.example ",
               password: "secret",
               host: " mail.eas.example ",
               port: "443"
             })

    settings = Repo.get_by!(EasSettings, external_account_id: account.id)
    assert settings.host == "mail.eas.example"
    assert settings.username == "padded@eas.example"
    assert settings.port == 443
    assert account.email_address == "padded@eas.example"
  end

  test "create_eas_account rejects auth failure without persisting" do
    before = Repo.aggregate(ReceiveMethod, :count)

    assert {:error, _} =
             Connectors.create_eas_account(%{
               email_address: "reader@eas-fail.example",
               username: "reader@eas-fail.example",
               password: "wrong",
               host: "mail.eas.example",
               port: 443
             })

    assert Repo.aggregate(ReceiveMethod, :count) == before
  end

  test "test_eas_connection returns error for invalid settings without raising" do
    assert {:error, %Manifold.Core.Error{reason: :invalid_eas_settings}} =
             Connectors.test_eas_connection(%{
               email_address: "reader@eas.example",
               username: "reader@eas.example",
               password: "secret",
               host: "",
               port: 443
             })
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end
