defmodule Manifold.Core.SignedRequest do
  @moduledoc """
  Signs and verifies the shared edge API request contract.

  The signature covers the protocol version, normalized HTTP method, path,
  timestamp, and a SHA-256 digest of the exact request body.
  """

  @version "v1"
  @default_max_skew_seconds 300

  @type verification_error :: :invalid_signature | :timestamp_out_of_range

  @type request_context :: [
          installation_id: binary(),
          authority: binary(),
          nonce: binary()
        ]

  @spec sign(binary(), binary(), binary(), integer(), binary(), request_context()) :: binary()
  def sign(secret, method, path, timestamp, body, request_context)
      when is_binary(secret) and is_binary(method) and is_binary(path) and
             is_integer(timestamp) and is_binary(body) do
    :crypto.mac(
      :hmac,
      :sha256,
      secret,
      canonical_request(method, path, timestamp, body, request_context)
    )
    |> Base.encode16(case: :lower)
  end

  @spec verify(binary(), binary(), binary(), binary(), integer(), binary(), keyword()) ::
          :ok | {:error, verification_error()}
  def verify(secret, signature, method, path, timestamp, body, opts \\ [])
      when is_binary(secret) and is_binary(signature) and is_binary(method) and
             is_binary(path) and is_integer(timestamp) and is_binary(body) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    max_skew_seconds = Keyword.get(opts, :max_skew_seconds, @default_max_skew_seconds)
    request_context = Keyword.fetch!(opts, :request_context)

    if abs(now - timestamp) > max_skew_seconds do
      {:error, :timestamp_out_of_range}
    else
      verify_signature(
        sign(secret, method, path, timestamp, body, request_context),
        signature
      )
    end
  end

  defp canonical_request(method, path, timestamp, body, request_context) do
    body_digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    Enum.join(
      [
        @version,
        Keyword.fetch!(request_context, :installation_id),
        String.upcase(method),
        Keyword.fetch!(request_context, :authority),
        path,
        Integer.to_string(timestamp),
        Keyword.fetch!(request_context, :nonce),
        body_digest
      ],
      "\n"
    )
  end

  defp verify_signature(expected, signature) do
    with {:ok, expected_bytes} <- Base.decode16(expected, case: :mixed),
         {:ok, signature_bytes} <- Base.decode16(signature, case: :mixed),
         true <- byte_size(expected_bytes) == byte_size(signature_bytes),
         true <- :crypto.hash_equals(expected_bytes, signature_bytes) do
      :ok
    else
      _error -> {:error, :invalid_signature}
    end
  end
end
