defmodule Manifold.Connectors.IMAP.TelemetryTest do
  use ExUnit.Case, async: false

  alias Manifold.Connectors.IMAP.Fake

  setup do
    handler_id = "imap-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:manifold, :connectors, :imap, :connect, :stop],
          [:manifold, :connectors, :imap, :auth, :stop],
          [:manifold, :connectors, :imap, :select, :stop]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "Fake connect success emits connect and auth stop with duration_ms" do
    account_id = Ecto.UUID.generate()

    assert {:ok, conn} =
             Fake.connect(%{
               host: "imap.example",
               port: 993,
               tls_mode: "ssl",
               username: "user@example",
               password: "secret",
               password_expected: "secret",
               account_id: account_id
             })

    assert_receive {:telemetry, [:manifold, :connectors, :imap, :connect, :stop],
                    %{duration_ms: connect_ms},
                    %{account_id: ^account_id, result: :ok, provider: "imap"}}

    assert is_integer(connect_ms)

    assert_receive {:telemetry, [:manifold, :connectors, :imap, :auth, :stop],
                    %{duration_ms: auth_ms}, meta}

    assert is_integer(auth_ms)
    assert meta.account_id == account_id
    assert meta.result == :ok
    assert meta.username == "user@example"
    assert meta.provider == "imap"
    refute Map.has_key?(meta, :password)

    assert {:ok, %{uidvalidity: 1}} = Fake.select(conn, "INBOX")

    assert_receive {:telemetry, [:manifold, :connectors, :imap, :select, :stop],
                    %{duration_ms: _},
                    %{
                      account_id: ^account_id,
                      result: :ok,
                      mailbox_path: "INBOX",
                      uidvalidity: 1
                    }}

    Fake.logout(conn)
  end

  test "Fake auth failure emits connect ok and auth error" do
    account_id = Ecto.UUID.generate()

    assert {:error, %{code: :auth_failed}} =
             Fake.connect(%{
               host: "imap.example",
               port: 993,
               tls_mode: "ssl",
               username: "user@example",
               password: "wrong",
               password_expected: "secret",
               account_id: account_id
             })

    assert_receive {:telemetry, [:manifold, :connectors, :imap, :connect, :stop], _,
                    %{result: :ok, account_id: ^account_id}}

    assert_receive {:telemetry, [:manifold, :connectors, :imap, :auth, :stop], _,
                    %{
                      result: :error,
                      error_code: :auth_failed,
                      account_id: ^account_id
                    }}
  end
end
