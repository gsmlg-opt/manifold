defmodule Manifold.Connectors.IMAP.FakeTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.IMAP.Fake

  test "fake transport login select search fetch" do
    settings = %{
      host: "fake",
      port: 993,
      tls_mode: "ssl",
      username: "user@example.com",
      password: "secret",
      mailbox_path: "INBOX",
      messages: [{1, "Subject: one\r\n\r\nHi\r\n"}, {2, "Subject: two\r\n\r\nYo\r\n"}],
      uidvalidity: 9
    }

    assert {:ok, conn} = Fake.connect(settings)
    assert {:ok, %{uidvalidity: 9}} = Fake.select(conn, "INBOX")
    assert {:ok, [1, 2]} = Fake.uid_search(conn, "ALL")
    assert {:ok, "Subject: one" <> _} = Fake.uid_fetch_rfc822(conn, 1)
    assert :ok = Fake.logout(conn)
  end

  test "fake transport auth failure" do
    settings = %{
      host: "fake",
      port: 993,
      tls_mode: "ssl",
      username: "user@example.com",
      password: "wrong",
      mailbox_path: "INBOX",
      password_expected: "secret",
      messages: [],
      uidvalidity: 1
    }

    assert {:error, %Manifold.Connectors.Provider.Error{class: :reconnect}} =
             Fake.connect(settings)
  end
end
