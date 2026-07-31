defmodule ManifoldAPI.Discovery do
  @moduledoc """
  Product discovery document for `GET /.well-known/manifold`.
  """

  alias ManifoldAPI.Endpoint

  @capabilities ["mail.read", "mail.search", "attachments.download"]

  @doc """
  Returns the well-known discovery map with absolute API URLs.
  """
  def document do
    base = Endpoint.url()

    %{
      product: "manifold",
      version: version(),
      auth: "deployment_boundary",
      api: %{
        rest: %{
          base: base <> "/api/v1",
          health: base <> "/api/v1/health"
        },
        graphql: %{
          http: base <> "/api/graphql"
        }
      },
      capabilities: @capabilities
    }
  end

  defp version do
    :manifold_api
    |> Application.spec(:vsn)
    |> List.to_string()
  end
end
