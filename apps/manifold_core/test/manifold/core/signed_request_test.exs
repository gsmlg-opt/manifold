defmodule Manifold.Core.SignedRequestTest do
  use ExUnit.Case, async: true

  alias Manifold.Core.SignedRequest

  @secret "shared-edge-secret"
  @timestamp 1_754_953_200
  @request_context [
    installation_id: "installation-1",
    authority: "edge.example.test",
    nonce: "nonce-1"
  ]

  test "signatures are deterministic and bind the method, path, timestamp, and body" do
    signature =
      SignedRequest.sign(
        @secret,
        "put",
        "/api/v1/route-snapshots",
        @timestamp,
        ~s({"revision":1}),
        @request_context
      )

    assert signature ==
             SignedRequest.sign(
               @secret,
               "PUT",
               "/api/v1/route-snapshots",
               @timestamp,
               ~s({"revision":1}),
               @request_context
             )

    refute signature ==
             SignedRequest.sign(
               @secret,
               "PUT",
               "/api/v1/route-snapshots",
               @timestamp,
               ~s({"revision":2}),
               @request_context
             )

    refute signature ==
             SignedRequest.sign(
               @secret,
               "PUT",
               "/api/v1/route-snapshots",
               @timestamp,
               ~s({"revision":1}),
               Keyword.put(@request_context, :nonce, "nonce-2")
             )
  end

  test "verifies a valid request within the allowed clock skew" do
    signature =
      SignedRequest.sign(
        @secret,
        "GET",
        "/api/v1/deliveries",
        @timestamp,
        "",
        @request_context
      )

    assert :ok =
             SignedRequest.verify(
               @secret,
               signature,
               "GET",
               "/api/v1/deliveries",
               @timestamp,
               "",
               now: @timestamp + 30,
               max_skew_seconds: 60,
               request_context: @request_context
             )
  end

  test "rejects tampered and malformed signatures" do
    signature =
      SignedRequest.sign(
        @secret,
        "GET",
        "/api/v1/deliveries",
        @timestamp,
        "",
        @request_context
      )

    assert {:error, :invalid_signature} =
             SignedRequest.verify(
               @secret,
               signature,
               "GET",
               "/api/v1/status",
               @timestamp,
               "",
               now: @timestamp,
               request_context: @request_context
             )

    assert {:error, :invalid_signature} =
             SignedRequest.verify(
               @secret,
               "not-hex",
               "GET",
               "/api/v1/deliveries",
               @timestamp,
               "",
               now: @timestamp,
               request_context: @request_context
             )
  end

  test "rejects requests outside the allowed clock skew" do
    signature =
      SignedRequest.sign(@secret, "GET", "/api/v1/status", @timestamp, "", @request_context)

    assert {:error, :timestamp_out_of_range} =
             SignedRequest.verify(
               @secret,
               signature,
               "GET",
               "/api/v1/status",
               @timestamp,
               "",
               now: @timestamp + 301,
               max_skew_seconds: 300,
               request_context: @request_context
             )
  end
end
