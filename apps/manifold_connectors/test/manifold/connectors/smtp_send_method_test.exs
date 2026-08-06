defmodule Manifold.Connectors.SmtpSendMethodTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.SMTP.Fake
  alias Manifold.Connectors.Schema.{SendCredential, SendMethod, SmtpSettings}
  alias Manifold.Repo

  setup do
    previous_transport = Application.get_env(:manifold_connectors, :smtp_transport)
    previous_fake = Application.get_env(:manifold_connectors, :smtp_fake)

    Application.put_env(:manifold_connectors, :smtp_transport, Fake)

    Application.put_env(:manifold_connectors, :smtp_fake, %{
      password_expected: "secret"
    })

    on_exit(fn ->
      restore_env(:smtp_transport, previous_transport)
      restore_env(:smtp_fake, previous_fake)
    end)

    {:ok, account} =
      Accounts.create_account(%{name: "Sender", address: "sender@smtp.example"})

    %{account: account}
  end

  test "create_smtp_send_method stores settings and strips spaces from password", %{
    account: account
  } do
    Application.put_env(:manifold_connectors, :smtp_fake, %{
      password_expected: "abcdefghijklmnop"
    })

    assert {:ok, method} =
             Connectors.create_smtp_send_method(%{
               account_id: account.id,
               email_address: "sender@smtp.example",
               username: "sender@smtp.example",
               password: "abcd efgh ijkl mnop",
               host: "smtp.example",
               port: 465,
               tls_mode: "tls"
             })

    settings = Repo.get_by!(SmtpSettings, send_method_id: method.id)
    assert settings.tls_mode == "tls"
    assert settings.host == "smtp.example"
    assert method.enabled
    assert method.kind == "smtp"
  end

  test "create_smtp_send_method stores password credential", %{account: account} do
    assert {:ok, method} =
             Connectors.create_smtp_send_method(%{
               account_id: account.id,
               email_address: "sender@smtp.example",
               username: "sender@smtp.example",
               password: "secret",
               host: "smtp.example",
               port: 465,
               tls_mode: "tls"
             })

    credential = Repo.get_by!(SendCredential, send_method_id: method.id)
    assert is_binary(credential.password_ciphertext)

    assert [view] = Connectors.list_send_methods_for_account(account.id)
    assert view.id == method.id
    assert view.enabled
  end

  test "create_smtp_send_method trims host and username before connect and persist", %{
    account: account
  } do
    assert {:ok, method} =
             Connectors.create_smtp_send_method(%{
               account_id: account.id,
               email_address: "  sender@smtp.example ",
               username: "  sender@smtp.example ",
               password: "secret",
               host: " smtp.example ",
               port: "587",
               tls_mode: "starttls"
             })

    settings = Repo.get_by!(SmtpSettings, send_method_id: method.id)
    assert settings.host == "smtp.example"
    assert settings.username == "sender@smtp.example"
    assert settings.port == 587
    assert method.email_address == "sender@smtp.example"
  end

  test "create_smtp_send_method rejects auth failure without persisting", %{account: account} do
    before = Repo.aggregate(SendMethod, :count)

    assert {:error, _} =
             Connectors.create_smtp_send_method(%{
               account_id: account.id,
               email_address: "sender@smtp.example",
               username: "sender@smtp.example",
               password: "wrong",
               host: "smtp.example",
               port: 465,
               tls_mode: "tls"
             })

    assert Repo.aggregate(SendMethod, :count) == before
  end

  test "test_smtp_connection returns error for invalid settings without raising" do
    assert {:error, %Manifold.Core.Error{reason: :invalid_smtp_settings}} =
             Connectors.test_smtp_connection(%{
               email_address: "sender@smtp.example",
               username: "sender@smtp.example",
               password: "secret",
               host: "",
               port: 465,
               tls_mode: "tls"
             })
  end

  test "enable and disconnect send method", %{account: account} do
    assert {:ok, method} =
             Connectors.create_smtp_send_method(%{
               account_id: account.id,
               email_address: "sender@smtp.example",
               username: "sender@smtp.example",
               password: "secret",
               host: "smtp.example",
               port: 465,
               tls_mode: "tls"
             })

    assert {:ok, disconnected} = Connectors.disconnect_send_method(method.id)
    assert disconnected.status == "disconnected"
    refute disconnected.enabled
    assert is_nil(Repo.get_by(SendCredential, send_method_id: method.id))
    assert is_nil(Repo.get_by(SmtpSettings, send_method_id: method.id))
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end
