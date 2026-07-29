defmodule Manifold.Cloud.Client do
  @moduledoc """
  Signed HTTP client for the local-initiated cloud ingress protocol.
  """

  alias Manifold.Accounts.RecipientSnapshot
  alias Manifold.Core.{Error, ID, SignedRequest}

  @snapshot_path "/api/v1/route-snapshots"
  @deliveries_path "/api/v1/deliveries"

  @spec publish_snapshot(keyword(), RecipientSnapshot.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def publish_snapshot(source, %RecipientSnapshot{} = snapshot, opts \\ []) do
    body = Jason.encode!(snapshot)

    case request(source, :put, @snapshot_path, body, opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, Error.new(:temporary, :edge_http_error, "edge returned HTTP #{status}")}

      {:ok, %Req.Response{status: status}} ->
        {:error, Error.new(:permanent, :edge_protocol_error, "edge returned HTTP #{status}")}

      {:error, _reason} ->
        {:error, Error.new(:temporary, :edge_unavailable, "edge request failed")}
    end
  end

  @spec list_deliveries(keyword(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_deliveries(source, opts \\ []) do
    case request(source, :get, @deliveries_path, "", opts) do
      {:ok, %Req.Response{status: 200, body: %{"deliveries" => deliveries}}}
      when is_list(deliveries) ->
        {:ok, deliveries}

      response ->
        classify_read_response(response)
    end
  end

  @spec fetch_raw(keyword(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def fetch_raw(source, edge_delivery_id, opts \\ []) do
    with :ok <- validate_edge_delivery_id(edge_delivery_id),
         {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) <-
           request(
             source,
             :get,
             "#{@deliveries_path}/#{edge_delivery_id}/raw",
             "",
             opts
           ) do
      {:ok, body}
    else
      {:error, %Error{}} = failure -> failure
      response -> classify_read_response(response)
    end
  end

  @spec stream_raw(keyword(), String.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_raw(source, edge_delivery_id, opts \\ []) do
    with :ok <- validate_edge_delivery_id(edge_delivery_id),
         {:ok, %Req.Response{status: 200, body: body}} <-
           request(
             source,
             :get,
             "#{@deliveries_path}/#{edge_delivery_id}/raw",
             "",
             Keyword.put(opts, :response_into, :self)
           ) do
      case body do
        %Req.Response.Async{} = stream -> {:ok, stream}
        body when is_binary(body) -> {:ok, [body]}
      end
    else
      {:error, %Error{}} = failure -> failure
      response -> classify_read_response(response)
    end
  end

  @spec acknowledge(keyword(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def acknowledge(source, edge_delivery_id, local_delivery_id, raw_sha256, opts \\ []) do
    with :ok <- validate_edge_delivery_id(edge_delivery_id) do
      body =
        Jason.encode!(%{
          local_delivery_id: local_delivery_id,
          raw_sha256: raw_sha256
        })

      path = "#{@deliveries_path}/#{edge_delivery_id}/acknowledgements"

      case request(source, :post, path, body, opts) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        response ->
          classify_read_response(response)
      end
    end
  end

  @spec report_failure(keyword(), String.t(), String.t(), atom(), keyword()) ::
          :ok | {:error, Error.t()}
  def report_failure(source, edge_delivery_id, raw_sha256, reason, opts \\ [])
      when is_atom(reason) do
    with :ok <- validate_edge_delivery_id(edge_delivery_id) do
      body =
        Jason.encode!(%{
          raw_sha256: raw_sha256,
          reason: Atom.to_string(reason)
        })

      path = "#{@deliveries_path}/#{edge_delivery_id}/failures"

      case request(source, :post, path, body, opts) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        response ->
          classify_read_response(response)
      end
    end
  end

  defp request(source, method, path, body, opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    nonce = Keyword.get_lazy(opts, :nonce, &generate_nonce/0)

    request_context = [
      installation_id: Keyword.fetch!(source, :installation_id),
      authority: Keyword.fetch!(source, :authority),
      nonce: nonce
    ]

    signature =
      SignedRequest.sign(
        Keyword.fetch!(source, :secret),
        method |> Atom.to_string() |> String.upcase(),
        path,
        now,
        body,
        request_context
      )

    headers = [
      {"x-manifold-installation", request_context[:installation_id]},
      {"x-manifold-timestamp", Integer.to_string(now)},
      {"x-manifold-nonce", nonce},
      {"x-manifold-signature", signature}
    ]

    headers =
      if body == "" do
        headers
      else
        [{"content-type", "application/json"} | headers]
      end

    request_options = [
      method: method,
      url: Keyword.fetch!(source, :base_url) <> path,
      retry: false,
      redirect: false,
      headers: headers
    ]

    request_options =
      if body == "" do
        request_options
      else
        Keyword.put(request_options, :body, body)
      end

    request_options =
      case Keyword.get(opts, :response_into) do
        nil -> request_options
        into -> Keyword.put(request_options, :into, into)
      end

    request_options
    |> Keyword.merge(Keyword.get(source, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.request()
  end

  defp classify_read_response({:ok, %Req.Response{status: status}}) when status >= 500 do
    {:error, Error.new(:temporary, :edge_http_error, "edge returned HTTP #{status}")}
  end

  defp classify_read_response({:ok, %Req.Response{status: status}}) do
    {:error, Error.new(:permanent, :edge_protocol_error, "edge returned HTTP #{status}")}
  end

  defp classify_read_response({:error, _reason}) do
    {:error, Error.new(:temporary, :edge_unavailable, "edge request failed")}
  end

  defp validate_edge_delivery_id(edge_delivery_id) do
    if ID.safe_path_id?(edge_delivery_id) do
      :ok
    else
      {:error, Error.new(:permanent, :invalid_edge_delivery_id, "invalid edge delivery ID")}
    end
  end

  defp generate_nonce do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
