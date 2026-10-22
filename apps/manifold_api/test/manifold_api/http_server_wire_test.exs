Code.require_file("../../../../test/support/http_wire.exs", __DIR__)

defmodule ManifoldAPI.HTTPServerWireTest do
  use ExUnit.Case, async: false
  alias Manifold.HTTPWire, as: Wire

  setup do
    %{port: Wire.start_endpoint(ManifoldAPI.Endpoint, :manifold_api)}
  end

  test "preserves the existing JSON parser body limit for GraphQL POST", %{port: port} do
    payload = %{query: "{ health { status } }", variables: %{padding: ""}}
    target_bytes = 7_999_999
    padding = String.duplicate("x", target_bytes - byte_size(Jason.encode!(payload)))
    body = payload |> Map.put(:variables, %{padding: padding}) |> Jason.encode!()
    assert byte_size(body) == target_bytes

    response =
      Wire.request(port, "POST", "/api/graphql", [{"content-type", "application/json"}], body)

    assert response.status == 200
    assert %{"data" => %{"health" => %{"status" => "ok"}}} = Jason.decode!(response.body)
  end

  test "Endpoint owns a discoverable Gaoxy listener serving health and GraphQL JSON", %{
    port: port
  } do
    response = Wire.request(port, "GET", "/api/v1/health", [{"accept", "application/json"}])
    assert response.status == 200
    assert %{"status" => "ok"} = Jason.decode!(response.body)

    response =
      Wire.request(
        port,
        "POST",
        "/api/graphql",
        [{"content-type", "application/json"}],
        Jason.encode!(%{query: "{ health { status } }"})
      )

    assert response.status == 200
    assert %{"data" => %{"health" => %{"status" => "ok"}}} = Jason.decode!(response.body)
  end
end
