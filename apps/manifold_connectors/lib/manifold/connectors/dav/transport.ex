defmodule Manifold.Connectors.DAV.Transport do
  @moduledoc false
  alias Manifold.Connectors.DAV.MintAdapter

  def request(method, url, headers, body, opts \\ []) do
    request =
      Req.new(
        method: method,
        url: url,
        headers: headers,
        body: body,
        adapter: MintAdapter,
        redirect: false,
        retry: false,
        decode_body: false,
        raw: true,
        compressed: false
      )

    request = Req.Request.register_options(request, [:dav_timeout, :dav_max_body_bytes])

    case Req.request(request,
           dav_timeout: Keyword.get(opts, :timeout, 15_000),
           dav_max_body_bytes: Keyword.get(opts, :max_body_bytes, 8 * 1024 * 1024)
         ) do
      {:ok, response} ->
        {:ok, %{status: response.status, headers: response.headers, body: response.body}}

      {:error, %Req.TransportError{reason: reason}}
      when reason in [:response_limit, :header_limit, :timeout] ->
        {:error, reason}

      {:error, _} ->
        {:error, :transport_failure}
    end
  rescue
    _ -> {:error, :transport_failure}
  end
end
