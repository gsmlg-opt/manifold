defmodule Manifold.Outbound.Provider.MicrosoftGraph do
  @moduledoc """
  Microsoft Graph MIME submission adapter.

  A transport failure is retryable only when it contains explicit evidence that
  no request bytes were transmitted. All other transport and server failures
  are uncertain because Microsoft may already have accepted the message.
  """

  @behaviour Manifold.Outbound.Provider

  alias Manifold.Core.HTTPClient

  alias Manifold.Connectors.MicrosoftSyncLimiter
  alias Manifold.Connectors.Provider.Error, as: ConnectorError
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
  @policy_rejection_codes [
    "erroraccessdenied",
    "mailboxaccessdenied",
    "tenantpolicyrejected"
  ]
  @max_json_prefix_depth 64
  @max_graph_error_code_candidates 8
  @bounded_error_codes @authentication_codes ++
                         @insufficient_scope_codes ++
                         @policy_rejection_codes
  @graph_error_code_token ~r/(?<!\\)"code"\s*:\s*"([A-Za-z0-9_.:-]{1,128})"/

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
      case Keyword.get(config, :microsoft_sync) do
        nil -> perform_request(uri, access_token, raw_message, transport)
        context -> paced_request(context, uri, access_token, raw_message, transport)
      end
    end
  end

  defp paced_request(context, uri, access_token, raw_message, transport) do
    # Only a definite rejection can become a retryable shared cooldown.
    # Uncertain POST outcomes must retain their original classification.
    result =
      MicrosoftSyncLimiter.run(
        context,
        fn ->
          case perform_request(uri, access_token, raw_message, transport) do
            {:error, %Error{class: :transient, code: "rate_limited"} = error} ->
              {:error,
               %ConnectorError{
                 class: :temporary,
                 code: :http_429,
                 message: error.message,
                 retry_after_seconds: error.retry_after
               }}

            result ->
              result
          end
        end,
        on_cooldown: fn error ->
          {:error,
           %Error{
             class: :transient,
             code: "provider_cooldown",
             message: "Microsoft Graph request is waiting for shared cooldown",
             retry_after: error.retry_after_seconds
           }}
        end
      )

    case result do
      {:error, %ConnectorError{} = error} ->
        code = if error.code == :http_429, do: "rate_limited", else: "provider_unavailable"
        http_status = if error.code == :http_429, do: 429, else: nil

        {:error,
         %Error{
           class: :transient,
           code: code,
           message: error.message,
           http_status: http_status,
           retry_after: error.retry_after_seconds
         }}

      {:ok, _} ->
        MicrosoftSyncLimiter.success(context)
        result

      result ->
        result
    end
  end

  defp perform_request(uri, access_token, raw_message, transport) do
    case request(uri, access_token, Base.encode64(raw_message), transport) do
      {:ok, %HTTPClient.Response{status: 202, private: %{manifold_raw_body_size: 0}} = response} ->
        accepted(response)

      {:ok, %HTTPClient.Response{status: 202}} ->
        {:error, invalid_response(202)}

      {:ok, %HTTPClient.Response{} = response} ->
        {:error, classify_response(response)}

      {:error, reason} ->
        {:error, classify_transport_failure(reason)}
    end
  end

  defp accepted(response) do
    {:ok,
     %Submission{
       provider_message_id: nil,
       metadata: diagnostic_metadata(response)
     }}
  end

  defp request(uri, access_token, encoded_message, transport) do
    options = [
      method: :post,
      url: URI.to_string(uri),
      auth: {:bearer, access_token},
      body: encoded_message,
      headers: [{"content-type", "text/plain"}],
      receive_timeout: transport.receive_timeout,
      pool_timeout: transport.pool_timeout,
      connect_options: [timeout: transport.connect_timeout, protocols: [:http1]],
      retry: false,
      redirect: false,
      decode_body: false,
      retain_body_bytes: @max_response_body_bytes,
      max_body_bytes: :infinity,
      max_header_bytes: 32 * 1024
    ]

    options = if transport.plug, do: Keyword.put(options, :plug, transport.plug), else: options

    case HTTPClient.request(options) do
      {:ok, %HTTPClient.Response{body: body} = response} when is_binary(body) ->
        {:ok, normalize_response(response, body, Map.fetch!(response.private, :raw_body_size))}

      result ->
        result
    end
  end

  defp normalize_response(response, body, raw_body_size) do
    retained_body = binary_part(body, 0, min(byte_size(body), @max_response_body_bytes))

    private =
      response.private
      |> Map.put(:manifold_raw_body_size, raw_body_size)
      |> Map.put(
        :manifold_graph_error_codes,
        bounded_graph_error_codes(retained_body, raw_body_size > byte_size(retained_body))
      )

    headers =
      response.headers
      |> Map.take(@relevant_response_headers)
      |> Map.new(fn {name, values} ->
        values =
          Enum.filter(values, &(is_binary(&1) and byte_size(&1) <= @max_response_header_bytes))

        {name, Enum.take(values, 2)}
      end)

    %{response | headers: headers, body: decode_body(retained_body), private: private}
  end

  defp bounded_graph_error_codes(body, true) do
    @graph_error_code_token
    |> Regex.scan(body, return: :index, capture: :all)
    |> Enum.take(@max_graph_error_code_candidates)
    |> Enum.reduce([], fn [{match_start, match_size}, {code_start, code_size}], codes ->
      code = body |> binary_part(code_start, code_size) |> canonical_code()

      if code in @bounded_error_codes and
           structural_graph_error_code?(body, match_start + match_size, code) do
        [code | codes]
      else
        codes
      end
    end)
    |> Enum.uniq()
  end

  defp bounded_graph_error_codes(_body, false), do: []

  defp structural_graph_error_code?(body, prefix_size, expected_code) do
    prefix = binary_part(body, 0, prefix_size)

    with {:ok, suffix} <- json_prefix_suffix(prefix),
         {:ok, decoded} <- JSON.decode(prefix <> suffix) do
      expected_code in graph_error_codes(decoded)
    else
      _invalid_prefix -> false
    end
  end

  defp json_prefix_suffix(prefix), do: scan_json_prefix(prefix, [], false, false)

  defp scan_json_prefix(<<>>, stack, false, false) do
    {:ok, List.to_string(stack)}
  end

  defp scan_json_prefix(<<>>, _stack, _in_string, _escaped), do: :error

  defp scan_json_prefix(<<_byte, rest::binary>>, stack, true, true) do
    scan_json_prefix(rest, stack, true, false)
  end

  defp scan_json_prefix(<<?\\, rest::binary>>, stack, true, false) do
    scan_json_prefix(rest, stack, true, true)
  end

  defp scan_json_prefix(<<?", rest::binary>>, stack, true, false) do
    scan_json_prefix(rest, stack, false, false)
  end

  defp scan_json_prefix(<<_byte, rest::binary>>, stack, true, false) do
    scan_json_prefix(rest, stack, true, false)
  end

  defp scan_json_prefix(<<?", rest::binary>>, stack, false, false) do
    scan_json_prefix(rest, stack, true, false)
  end

  defp scan_json_prefix(<<opening, rest::binary>>, stack, false, false)
       when opening in [?{, ?[] and length(stack) < @max_json_prefix_depth do
    closing = if opening == ?{, do: ?}, else: ?]
    scan_json_prefix(rest, [closing | stack], false, false)
  end

  defp scan_json_prefix(<<closing, rest::binary>>, [closing | stack], false, false)
       when closing in [?}, ?]] do
    scan_json_prefix(rest, stack, false, false)
  end

  defp scan_json_prefix(<<closing, _rest::binary>>, _stack, false, false)
       when closing in [?{, ?[, ?}, ?]],
       do: :error

  defp scan_json_prefix(<<_byte, rest::binary>>, stack, false, false) do
    scan_json_prefix(rest, stack, false, false)
  end

  defp decode_body(""), do: ""

  defp decode_body(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> ""
    end
  end

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
      {HTTPClient.Test, _name} = plug -> {:ok, plug}
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

  defp validate_authority(%URI{}, %{plug: {HTTPClient.Test, _name}}), do: :ok

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

  defp diagnostic_metadata(response) do
    Enum.reduce(@diagnostic_headers, %{}, fn {header, metadata_key}, metadata ->
      case HTTPClient.Response.get_header(response, header) do
        [value] when is_binary(value) ->
          if Regex.match?(@diagnostic_id, value),
            do: Map.put(metadata, metadata_key, value),
            else: metadata

        _missing_or_ambiguous ->
          metadata
      end
    end)
  end

  defp classify_response(%HTTPClient.Response{status: status, body: body} = response) do
    codes = graph_error_codes(body) ++ Map.get(response.private, :manifold_graph_error_codes, [])

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
        invalid_response(status)

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

  defp classify_transport_failure(%HTTPClient.TransportError{
         phase: :pre_transmission
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

  defp invalid_response(status) do
    error(
      :uncertain,
      "invalid_response",
      "Microsoft may have accepted the message",
      status
    )
  end

  defp request_rejected(status) do
    error(:permanent, "request_rejected", "Microsoft Graph rejected the request", status)
  end

  defp graph_error_codes(%{"error" => error}) when is_map(error) do
    graph_error_object_codes(error)
  end

  defp graph_error_codes(_value), do: []

  defp graph_error_object_codes(error) do
    own_codes =
      case Map.get(error, "code") do
        code when is_binary(code) -> [canonical_code(code)]
        _missing_or_invalid -> []
      end

    inner_codes =
      case Map.get(error, "innerError") do
        inner_error when is_map(inner_error) -> graph_error_object_codes(inner_error)
        _missing_or_invalid -> []
      end

    own_codes ++ inner_codes
  end

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
    case HTTPClient.Response.get_header(response, "retry-after") do
      [value] -> parse_retry_after(value)
      _missing_or_ambiguous -> nil
    end
  end

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        seconds

      _not_seconds ->
        with {:ok, retry_at} <- HTTPClient.parse_http_date(value),
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
