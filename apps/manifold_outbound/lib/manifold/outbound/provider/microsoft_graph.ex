defmodule Manifold.Outbound.Provider.MicrosoftGraph do
  @moduledoc """
  Microsoft Graph MIME submission adapter.

  A transport failure is retryable only when it contains explicit evidence that
  no request bytes were transmitted. All other transport and server failures
  are uncertain because Microsoft may already have accepted the message.
  """

  @behaviour Manifold.Outbound.Provider

  alias Manifold.Outbound.Provider.{Error, Request, Submission}

  @default_base_url "https://graph.microsoft.com/v1.0"
  @send_path "/me/sendMail"
  @default_receive_timeout 15_000
  @default_connect_timeout 5_000
  @default_pool_timeout 5_000
  @max_timeout 120_000
  @max_response_body_bytes 64 * 1024
  @max_response_header_bytes 256
  @relevant_response_headers ["request-id", "client-request-id", "retry-after"]
  @diagnostic_id ~r/\A[A-Za-z0-9._:-]{1,128}\z/
  @diagnostic_headers [
    {"request-id", "request_id"},
    {"client-request-id", "client_request_id"}
  ]
  @authentication_codes ["invalidauthenticationtoken"]
  @insufficient_scope_codes [
    "authorizationrequestdenied",
    "insufficientpermissions",
    "insufficientscope"
  ]

  @impl true
  def submit(config, %Request{raw_message: raw_message}) when is_list(config) do
    if Keyword.keyword?(config) do
      case Keyword.get(config, :access_token) do
        access_token when is_binary(access_token) and access_token != "" ->
          submit_with_token(config, raw_message, access_token)

        _missing ->
          {:error,
           error(
             :permanent,
             "provider_not_configured",
             "Microsoft access token is not configured"
           )}
      end
    else
      invalid_transport_config()
    end
  end

  defp submit_with_token(config, raw_message, access_token) do
    base_url = Keyword.get(config, :base_url, configured_base_url())

    with {:ok, transport} <- transport_config(Keyword.get(config, :req_options, [])),
         {:ok, uri} <- submission_uri(base_url, transport) do
      perform_request(uri, access_token, raw_message, transport)
    end
  end

  defp perform_request(uri, access_token, raw_message, transport) do
    case request(uri, access_token, Base.encode64(raw_message), transport) do
      {:ok, %Req.Response{status: 202} = response} ->
        {:ok,
         %Submission{
           provider_message_id: nil,
           metadata: diagnostic_metadata(response)
         }}

      {:ok, %Req.Response{} = response} ->
        {:error, classify_response(response)}

      {:error, reason} ->
        {:error, classify_transport_failure(reason)}
    end
  end

  defp request(uri, access_token, encoded_message, %{plug: plug} = transport)
       when not is_nil(plug) do
    Req.request(
      method: :post,
      url: URI.to_string(uri),
      auth: {:bearer, access_token},
      body: encoded_message,
      headers: [{"content-type", "text/plain"}],
      plug: plug,
      receive_timeout: transport.receive_timeout,
      retry: false,
      redirect: false
    )
  end

  defp request(uri, access_token, encoded_message, transport) do
    mint_request(uri, access_token, encoded_message, transport)
  end

  defp mint_request(uri, access_token, encoded_message, transport) do
    connect_options = [
      mode: :passive,
      protocols: [:http1],
      log: false,
      max_header_list_size: 32 * 1024,
      transport_opts: [
        timeout: transport.connect_timeout,
        send_timeout: transport.pool_timeout,
        send_timeout_close: true,
        cacerts: :public_key.cacerts_get()
      ]
    ]

    case Mint.HTTP.connect(:https, uri.host, uri.port || 443, connect_options) do
      {:ok, conn} ->
        mint_send(conn, uri, access_token, encoded_message, transport.receive_timeout)

      {:error, reason} ->
        {:error, pre_transmission_error(reason)}
    end
  end

  defp mint_send(conn, uri, access_token, encoded_message, receive_timeout) do
    headers = [
      {"authorization", "Bearer " <> access_token},
      {"content-type", "text/plain"}
    ]

    result =
      case Mint.HTTP.request(conn, "POST", request_target(uri), headers, encoded_message) do
        {:ok, conn, request_ref} ->
          mint_receive(conn, request_ref, receive_timeout, %{
            status: nil,
            headers: [],
            body: [],
            body_size: 0
          })

        {:error, conn, reason} ->
          close_mint(conn)
          {:error, post_transmission_error(reason)}
      end

    result
  end

  defp mint_receive(conn, request_ref, receive_timeout, response) do
    case Mint.HTTP.recv(conn, 0, receive_timeout) do
      {:ok, conn, responses} ->
        handle_mint_responses(conn, request_ref, receive_timeout, response, responses)

      {:error, conn, reason, responses} ->
        close_mint(conn)

        case accumulate_mint_responses(response, request_ref, responses) do
          {:done, complete} -> {:ok, mint_response(complete)}
          {:error, stream_reason} -> {:error, post_transmission_error(stream_reason)}
          {:more, _partial} -> {:error, post_transmission_error(reason)}
        end
    end
  end

  defp handle_mint_responses(conn, request_ref, receive_timeout, response, responses) do
    case accumulate_mint_responses(response, request_ref, responses) do
      {:done, complete} ->
        close_mint(conn)
        {:ok, mint_response(complete)}

      {:error, reason} ->
        close_mint(conn)
        {:error, post_transmission_error(reason)}

      {:more, partial} ->
        mint_receive(conn, request_ref, receive_timeout, partial)
    end
  end

  defp accumulate_mint_responses(response, request_ref, responses) do
    Enum.reduce_while(responses, {:more, response}, fn
      {:status, ^request_ref, status}, {:more, acc} ->
        {:cont, {:more, %{acc | status: status}}}

      {:headers, ^request_ref, headers}, {:more, acc} ->
        {:cont, {:more, %{acc | headers: retain_relevant_headers(acc.headers, headers)}}}

      {:data, ^request_ref, data}, {:more, acc} ->
        append_mint_body(acc, data)

      {:done, ^request_ref}, {:more, acc} ->
        {:halt, {:done, acc}}

      {:error, ^request_ref, reason}, {:more, _acc} ->
        {:halt, {:error, reason}}

      _other_response, state ->
        {:cont, state}
    end)
  end

  defp retain_relevant_headers(retained, headers) do
    Enum.reduce(headers, retained, fn
      {name, value}, acc
      when is_binary(name) and is_binary(value) and
             byte_size(name) <= @max_response_header_bytes and
             byte_size(value) <= @max_response_header_bytes ->
        normalized_name = String.downcase(name, :ascii)

        if normalized_name in @relevant_response_headers and
             Enum.count(acc, &(elem(&1, 0) == normalized_name)) < 2 do
          [{normalized_name, value} | acc]
        else
          acc
        end

      _invalid_header, acc ->
        acc
    end)
  end

  defp append_mint_body(%{body_size: size} = acc, data) when is_binary(data) do
    new_size = size + byte_size(data)

    if new_size <= @max_response_body_bytes do
      {:cont, {:more, %{acc | body: [data | acc.body], body_size: new_size}}}
    else
      {:halt, {:error, :response_body_too_large}}
    end
  end

  defp mint_response(response) do
    body = response.body |> Enum.reverse() |> IO.iodata_to_binary() |> decode_mint_body()

    %Req.Response{
      status: response.status,
      headers: Req.Fields.new(response.headers),
      body: body
    }
  end

  defp decode_mint_body(""), do: ""

  defp decode_mint_body(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> ""
    end
  end

  defp request_target(%URI{path: path, query: nil}), do: path

  defp transport_config(options) when is_list(options) do
    with :ok <- validate_keyword_options(options),
         {:ok, plug} <- plug_option(options),
         {:ok, receive_timeout} <-
           timeout_option(options, :receive_timeout, @default_receive_timeout),
         {:ok, pool_timeout} <- timeout_option(options, :pool_timeout, @default_pool_timeout),
         {:ok, connect_timeout} <- connect_timeout_option(options) do
      {:ok,
       %{
         plug: plug,
         receive_timeout: receive_timeout,
         pool_timeout: pool_timeout,
         connect_timeout: connect_timeout
       }}
    else
      :error -> invalid_transport_config()
    end
  end

  defp transport_config(_invalid), do: invalid_transport_config()

  defp validate_keyword_options(options) do
    if Keyword.keyword?(options), do: :ok, else: :error
  end

  defp plug_option(options) do
    case Keyword.get(options, :plug) do
      nil -> {:ok, nil}
      {Req.Test, _name} = plug -> {:ok, plug}
      _invalid -> :error
    end
  end

  defp timeout_option(options, key, default) do
    case Keyword.get(options, key, default) do
      timeout when is_integer(timeout) and timeout in 1..@max_timeout -> {:ok, timeout}
      _invalid -> :error
    end
  end

  defp connect_timeout_option(options) do
    case Keyword.get(options, :connect_options, []) do
      connect_options when is_list(connect_options) ->
        with :ok <- validate_keyword_options(connect_options) do
          timeout_option(connect_options, :timeout, @default_connect_timeout)
        end

      _invalid ->
        :error
    end
  end

  defp submission_uri(base_url, transport) when is_binary(base_url) do
    with {:ok, uri} <- URI.new(base_url),
         :ok <- validate_base_uri(uri),
         :ok <- validate_authority(uri, transport),
         :ok <- validate_base_path(uri.path) do
      {:ok, URI.append_path(uri, @send_path)}
    else
      _invalid -> invalid_endpoint_config()
    end
  end

  defp submission_uri(_base_url, _transport), do: invalid_endpoint_config()

  defp validate_base_uri(%URI{
         scheme: "https",
         host: host,
         port: port,
         userinfo: nil,
         query: nil,
         fragment: nil
       })
       when is_binary(host) and host != "" do
    if is_nil(port) or (is_integer(port) and port in 1..65_535), do: :ok, else: :error
  end

  defp validate_base_uri(_uri), do: :error

  defp validate_authority(%URI{}, %{plug: {Req.Test, _name}}), do: :ok

  defp validate_authority(%URI{} = uri, _transport) do
    with {:ok, trusted_uri} <- trusted_base_uri(),
         true <- same_authority?(uri, trusted_uri) do
      :ok
    else
      _invalid -> :error
    end
  end

  defp trusted_base_uri do
    with base_url when is_binary(base_url) <- configured_base_url(),
         {:ok, uri} <- URI.new(base_url),
         :ok <- validate_base_uri(uri),
         :ok <- validate_base_path(uri.path) do
      {:ok, uri}
    else
      _invalid -> :error
    end
  end

  defp configured_base_url do
    providers = Application.get_env(:manifold_connectors, :providers, [])

    if is_list(providers) and Keyword.keyword?(providers) do
      case Keyword.get(providers, :microsoft) do
        nil ->
          @default_base_url

        provider when is_list(provider) ->
          if Keyword.keyword?(provider),
            do: Keyword.get(provider, :base_url, @default_base_url),
            else: nil

        _invalid ->
          nil
      end
    else
      nil
    end
  end

  defp same_authority?(left, right) do
    String.downcase(left.host) == String.downcase(right.host) and
      effective_port(left) == effective_port(right)
  end

  defp effective_port(%URI{port: nil}), do: 443
  defp effective_port(%URI{port: port}), do: port

  defp validate_base_path(nil), do: :ok
  defp validate_base_path(""), do: :ok

  defp validate_base_path(path) when is_binary(path) do
    segments = String.split(path, "/", trim: true)

    if String.contains?(path, ["//", "\\", "%"]) or
         Enum.any?(segments, &(&1 in [".", ".."])) do
      :error
    else
      :ok
    end
  end

  defp invalid_endpoint_config do
    {:error, error(:permanent, "invalid_config", "Microsoft Graph endpoint is invalid")}
  end

  defp invalid_transport_config do
    {:error, error(:permanent, "invalid_config", "Microsoft Graph transport options are invalid")}
  end

  defp pre_transmission_error(reason) do
    %Req.TransportError{
      reason: {:manifold_transport_phase, :pre_transmission, safe_reason(reason)}
    }
  end

  defp post_transmission_error(reason) do
    %Req.TransportError{
      reason: {:manifold_transport_phase, :post_transmission, safe_reason(reason)}
    }
  end

  defp safe_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :transport_failure

  defp close_mint(conn) do
    _ = Mint.HTTP.close(conn)
    :ok
  end

  defp diagnostic_metadata(response) do
    Enum.reduce(@diagnostic_headers, %{}, fn {header, metadata_key}, metadata ->
      case Req.Response.get_header(response, header) do
        [value] when is_binary(value) ->
          if Regex.match?(@diagnostic_id, value),
            do: Map.put(metadata, metadata_key, value),
            else: metadata

        _missing_or_ambiguous ->
          metadata
      end
    end)
  end

  defp classify_response(%Req.Response{status: status, body: body} = response) do
    codes = graph_error_codes(body)

    cond do
      status == 429 ->
        error(
          :transient,
          "rate_limited",
          "Microsoft Graph rate limit reached",
          status,
          retry_after(response)
        )

      status in 500..599 ->
        acceptance_unknown(status)

      status in 200..299 ->
        error(
          :uncertain,
          "invalid_response",
          "Microsoft may have accepted the message",
          status
        )

      status == 401 or has_code?(codes, @authentication_codes) ->
        error(
          :permanent,
          "reconnect_required",
          "Microsoft authorization must be reconnected",
          status
        )

      status == 403 and has_code?(codes, @insufficient_scope_codes) ->
        error(
          :permanent,
          "insufficient_scope",
          "Microsoft authorization requires the send scope",
          status
        )

      status == 403 and policy_rejection?(codes) ->
        error(
          :permanent,
          "policy_rejected",
          "Microsoft policy rejected the request",
          status
        )

      status in 400..499 ->
        request_rejected(status)

      true ->
        request_rejected(status)
    end
  end

  defp classify_transport_failure(%Req.TransportError{
         reason: {:manifold_transport_phase, :pre_transmission, _reason}
       }) do
    error(:transient, "transport_error", "Microsoft request could not be transmitted")
  end

  defp classify_transport_failure(_unknown_or_post_dispatch) do
    error(:uncertain, "acceptance_unknown", "Microsoft may have accepted the message")
  end

  defp acceptance_unknown(status) do
    error(
      :uncertain,
      "acceptance_unknown",
      "Microsoft may have accepted the message",
      status
    )
  end

  defp request_rejected(status) do
    error(:permanent, "request_rejected", "Microsoft Graph rejected the request", status)
  end

  defp graph_error_codes(map) when is_map(map) do
    Enum.flat_map(map, fn
      {key, value} when key in ["code", "error"] and is_binary(value) ->
        [canonical_code(value)]

      {_key, value} ->
        graph_error_codes(value)
    end)
  end

  defp graph_error_codes(list) when is_list(list), do: Enum.flat_map(list, &graph_error_codes/1)
  defp graph_error_codes(_value), do: []

  defp canonical_code(code) do
    code
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/u, "")
  end

  defp has_code?(codes, expected), do: Enum.any?(codes, &(&1 in expected))

  defp policy_rejection?(codes) do
    Enum.any?(codes, fn code ->
      String.contains?(code, "accessdenied") or
        String.contains?(code, "tenant") or
        String.contains?(code, "policy")
    end)
  end

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value] -> parse_retry_after(value)
      _missing_or_ambiguous -> nil
    end
  end

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        seconds

      _not_seconds ->
        with {:ok, retry_at} <- Req.Utils.parse_http_date(value),
             seconds when seconds >= 0 <- DateTime.diff(retry_at, DateTime.utc_now(), :second) do
          seconds
        else
          _invalid_or_expired -> nil
        end
    end
  end

  defp error(class, code, message, http_status \\ nil, retry_after \\ nil) do
    %Error{
      class: class,
      code: code,
      message: String.slice(message, 0, 500),
      http_status: http_status,
      retry_after: retry_after
    }
  end
end
