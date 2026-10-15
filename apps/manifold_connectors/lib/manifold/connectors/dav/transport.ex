defmodule Manifold.Connectors.DAV.Transport do
  @moduledoc false
  alias Manifold.Core.HTTPClient

  def request(method, url, headers, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    case HTTPClient.request(
           method: method,
           url: url,
           headers: headers,
           body: body,
           receive_timeout: timeout,
           connect_options: [timeout: timeout, protocols: [:http1]],
           pool_timeout: timeout,
           retry: false,
           redirect: false,
           decode_body: false,
           compressed: false,
           max_body_bytes: Keyword.get(opts, :max_body_bytes, 8 * 1024 * 1024),
           max_header_bytes: 64 * 1024,
           max_header_count: 1_000
         ) do
      {:ok, response} ->
        headers =
          Map.merge(response.headers, response.trailers, fn _, values, trailers ->
            values ++ trailers
          end)

        {:ok, %{status: response.status, headers: headers, body: response.body}}

      {:error, %HTTPClient.TransportError{reason: reason}} ->
        {:error, transport_reason(reason)}

      {:error, _} ->
        {:error, :transport_failure}
    end
  rescue
    _ -> {:error, :transport_failure}
  end

  defp transport_reason(reason)
       when reason in [:response_limit, :header_limit, :timeout, :nxdomain],
       do: reason

  defp transport_reason(reason) when reason in [:request_timeout, :connect_timeout], do: :timeout

  defp transport_reason(reason) when reason in [:headers_too_large, :trailers_too_large],
    do: :header_limit

  defp transport_reason(_), do: :transport_failure
end
