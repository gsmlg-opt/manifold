defmodule Manifold.Connectors.ImapAccountTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.IMAP.Fake
  alias Manifold.Connectors.Schema.{Credential, ExternalAccount, ImapSettings}
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

    assert account.provider == "imap"
    assert account.email_address == "reader@imap.example"
    assert account.provider_account_id == "imap:reader@imap.example"

    mailbox = Accounts.get_mailbox!(account.mailbox_id) |> Repo.preload(:domain)
    assert mailbox.domain.normalized_domain == "imap.example"

    credential = Repo.get_by!(Credential, external_account_id: account.id)
    assert credential.secret_kind == "password"
    assert is_binary(credential.password_ciphertext)
    assert is_nil(credential.refresh_token_ciphertext)

    assert Repo.get_by!(ImapSettings, external_account_id: account.id).host == "imap.example"
  end

  test "create_imap_account rejects auth failure without persisting" do
    before = Repo.aggregate(ExternalAccount, :count)

    assert {:error, _} =
             Connectors.create_imap_account(%{
               email_address: "reader@imap-fail.example",
               username: "reader@imap-fail.example",
               password: "wrong",
               host: "imap.example",
               port: 993,
               tls_mode: "ssl"
             })

    assert Repo.aggregate(ExternalAccount, :count) == before
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end
