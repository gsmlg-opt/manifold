defmodule Manifold.Connectors.ImapAccountTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.IMAP.Fake
  alias Manifold.Connectors.Schema.{Credential, ReceiveMethod, ImapSettings}
  alias Manifold.Repo

  setup do
    previous_transport = Application.get_env(:manifold_connectors, :imap_transport)
    previous_fake = Application.get_env(:manifold_connectors, :imap_fake)

    Application.put_env(:manifold_connectors, :imap_transport, Fake)

    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      messages: [],
      uidvalidity: 1
    })

    on_exit(fn ->
      restore_env(:imap_transport, previous_transport)
      restore_env(:imap_fake, previous_fake)
    end)

    :ok
  end

  test "create_imap_account auto-creates mailbox and stores password credential" do
    assert {:ok, account} =
             Connectors.create_imap_account(%{
               email_address: "reader@imap.example",
               username: "reader@imap.example",
               password: "secret",
               host: "imap.example",
               port: 993,
               tls_mode: "ssl"
             })

    assert account.kind == "imap"
    assert account.email_address == "reader@imap.example"
    assert account.provider_account_id == "imap:reader@imap.example"

    mailbox = Accounts.get_account!(account.account_id) |> Repo.preload(:domain)
    assert mailbox.domain.normalized_domain == "imap.example"

    credential = Repo.get_by!(Credential, external_account_id: account.id)
    assert credential.secret_kind == "password"
    assert is_binary(credential.password_ciphertext)
    assert is_nil(credential.refresh_token_ciphertext)

    assert Repo.get_by!(ImapSettings, external_account_id: account.id).host == "imap.example"
  end

  test "create_imap_account trims host and username whitespace before connect and persist" do
    assert {:ok, account} =
             Connectors.create_imap_account(%{
               email_address: "  padded@imap.example ",
               username: "  padded@imap.example ",
               password: "secret",
               host: " imap.example ",
               port: "993",
               tls_mode: "ssl"
             })

    settings = Repo.get_by!(ImapSettings, external_account_id: account.id)
    assert settings.host == "imap.example"
    assert settings.username == "padded@imap.example"
    assert settings.port == 993
    assert account.email_address == "padded@imap.example"
  end

  test "create_imap_account rejects auth failure without persisting" do
    before = Repo.aggregate(ReceiveMethod, :count)

    assert {:error, _} =
             Connectors.create_imap_account(%{
               email_address: "reader@imap-fail.example",
               username: "reader@imap-fail.example",
               password: "wrong",
               host: "imap.example",
               port: 993,
               tls_mode: "ssl"
             })

    assert Repo.aggregate(ReceiveMethod, :count) == before
  end

  test "test_imap_connection returns error for invalid settings without raising" do
    assert {:error, %Manifold.Core.Error{reason: :invalid_imap_settings}} =
             Connectors.test_imap_connection(%{
               email_address: "reader@imap.example",
               username: "reader@imap.example",
               password: "secret",
               host: "",
               port: 993,
               tls_mode: "ssl"
             })
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end
