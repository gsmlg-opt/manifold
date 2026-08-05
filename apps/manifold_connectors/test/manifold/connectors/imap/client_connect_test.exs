defmodule Manifold.Connectors.IMAP.ClientConnectTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.IMAP.Client
  alias Manifold.Connectors.Provider.Error

  test "connect trims host whitespace before attempting TCP" do
    # Trimmed 127.0.0.1 on a closed port must return {:error, _} (not raise).
    assert {:error, %Error{class: :temporary, code: :connect_failed}} =
             Client.connect(%{
               host: " 127.0.0.1 ",
               port: 1,
               tls_mode: "starttls",
               username: "user@example.com",
               password: "secret"
             })
  end

  test "connect rejects invalid host type without raising" do
    assert {:error, %Error{code: :invalid_host}} =
             Client.connect(%{
               host: :not_a_host,
               port: 993,
               tls_mode: "starttls",
               username: "user@example.com",
               password: "secret"
             })
  end

  test "connect rejects invalid port without raising" do
    assert {:error, %Error{code: :invalid_port}} =
             Client.connect(%{
               host: "127.0.0.1",
               port: "not-a-port",
               tls_mode: "ssl",
               username: "user@example.com",
               password: "secret"
             })
  end

  test "open_and_greet converts gen_tcp ArgumentError/badarg to error tuple" do
    # Leading space in host makes OTP gen_tcp.connect raise/exit badarg.
    # This path must not crash the caller (LiveView).
    assert {:error, %Error{class: :temporary, code: :connect_failed}} =
             Client.open_and_greet_for_test(" imap.example.com", 993, "starttls")
  end
end
