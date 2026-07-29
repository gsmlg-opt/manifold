defmodule Manifold.Connectors.CryptoTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.Crypto

  @key :crypto.strong_rand_bytes(32)

  test "encrypts with a randomized authenticated envelope and decrypts with matching context" do
    assert {:ok, first} = Crypto.encrypt("refresh-token", "account-1", key: @key)
    assert {:ok, second} = Crypto.encrypt("refresh-token", "account-1", key: @key)
    refute first == second
    refute first =~ "refresh-token"

    assert {:ok, "refresh-token"} = Crypto.decrypt(first, "account-1", key: @key)

    assert {:error, %{class: :permanent, reason: :credential_authentication_failed}} =
             Crypto.decrypt(first, "account-2", key: @key)
  end

  test "rejects malformed envelopes and keys that are not 32 bytes" do
    assert {:error, %{reason: :invalid_encryption_key}} =
             Crypto.encrypt("secret", "context", key: "too-short")

    assert {:error, %{reason: :invalid_credential_envelope}} =
             Crypto.decrypt("malformed", "context", key: @key)
  end
end
