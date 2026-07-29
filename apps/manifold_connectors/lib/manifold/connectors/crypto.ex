defmodule Manifold.Connectors.Crypto do
  @moduledoc """
  Versioned authenticated encryption for connector credentials.
  """

  alias Manifold.Core.Error

  @version 1
  @nonce_bytes 12
  @tag_bytes 16
  @key_bytes 32

  @spec encrypt(binary(), binary(), Keyword.t()) :: {:ok, binary()} | {:error, Error.t()}
  def encrypt(plaintext, context, opts \\ [])
      when is_binary(plaintext) and is_binary(context) do
    with {:ok, key} <- encryption_key(opts) do
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          plaintext,
          context,
          @tag_bytes,
          true
        )

      {:ok, <<@version, nonce::binary, tag::binary, ciphertext::binary>>}
    end
  end

  @spec decrypt(binary(), binary(), Keyword.t()) :: {:ok, binary()} | {:error, Error.t()}
  def decrypt(envelope, context, opts \\ []) when is_binary(envelope) and is_binary(context) do
    with {:ok, key} <- encryption_key(opts),
         {:ok, nonce, tag, ciphertext} <- split_envelope(envelope) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             context,
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) ->
          {:ok, plaintext}

        :error ->
          {:error,
           Error.new(
             :permanent,
             :credential_authentication_failed,
             "encrypted connector credential failed authentication"
           )}
      end
    end
  end

  defp encryption_key(opts) do
    case Keyword.get(opts, :key) do
      key when is_binary(key) and byte_size(key) == @key_bytes ->
        {:ok, key}

      nil ->
        configured_key()

      _invalid ->
        invalid_key()
    end
  end

  defp configured_key do
    case Application.get_env(:manifold_connectors, :encryption_key) do
      encoded when is_binary(encoded) ->
        case Base.decode64(encoded) do
          {:ok, key} when byte_size(key) == @key_bytes -> {:ok, key}
          _invalid -> invalid_key()
        end

      _missing ->
        invalid_key()
    end
  end

  defp split_envelope(
         <<@version, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
           ciphertext::binary>>
       )
       when byte_size(ciphertext) > 0 do
    {:ok, nonce, tag, ciphertext}
  end

  defp split_envelope(_invalid) do
    {:error,
     Error.new(
       :permanent,
       :invalid_credential_envelope,
       "encrypted connector credential envelope is invalid"
     )}
  end

  defp invalid_key do
    {:error,
     Error.new(
       :permanent,
       :invalid_encryption_key,
       "connector encryption key must decode to exactly 32 bytes"
     )}
  end
end
