defmodule Manifold.Connectors.EAS.HTTPAdapter do
  @moduledoc false

  alias Manifold.Connectors.TLS
  alias Manifold.Core.HTTPClient
  alias Manifold.Core.HTTPClient.TransportError

  @max_header_bytes 64 * 1024
  @max_header_count 200
  @max_body_bytes 64 * 1024 * 1024

  @supported_options [
    :method,
    :url,
    :headers,
    :body,
    :receive_timeout,
    :connect_options,
    :decode_body,
    :compressed,
    :user_agent
  ]

  @spec validate_options(keyword(), TLS.Config.t()) :: :ok | {:error, atom()}
  def validate_options(options, %TLS.Config{backend: :ex_ssl, options: tls_options}) do
    with true <- Keyword.keyword?(options),
         true <- unique_keys?(options),
         true <- Enum.all?(Keyword.keys(options), &(&1 in @supported_options)),
         {:ok, false} <- Keyword.fetch(options, :decode_body),
         true <- Keyword.get(options, :compressed, false) == false,
         true <- Keyword.get(options, :user_agent, "") |> is_binary(),
         {:ok, _connect_timeout} <- timeout(Map.new(options), :connect_options, 15_000),
         {:ok, _receive_timeout} <- timeout(Map.new(options), :receive_timeout, 60_000),
         :ok <- validate_http1_profile(tls_options) do
      :ok
    else
      _ -> {:error, :unsupported_ex_ssl_http_options}
    end
  end

  def validate_options(_options, %TLS.Config{backend: :otp}), do: :ok

  @spec request(keyword(), TLS.Config.t()) ::
          {:ok, %HTTPClient.Response{}} | {:error, Exception.t()}
  def request(options, %TLS.Config{} = config) do
    with :ok <- validate_request_policy(options, config),
         :ok <- validate_options(options, config),
         {:ok, endpoint} <- validate_endpoint(options |> Keyword.fetch!(:url) |> URI.parse()),
         {:ok, _connect_timeout} <- timeout(Map.new(options), :connect_options, 15_000),
         {:ok, _receive_timeout} <- timeout(Map.new(options), :receive_timeout, 60_000),
         {:ok, method} <- method(Keyword.get(options, :method)),
         {:ok, body} <- body(Keyword.get(options, :body)),
         {:ok, headers} <- request_headers(options, endpoint, method, body) do
      ssl =
        [
          verify: :verify_peer,
          server_name_indication: String.to_charlist(endpoint.host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          versions:
            if(config.backend == :ex_ssl, do: [:"tlsv1.3"], else: [:"tlsv1.3", :"tlsv1.2"])
        ]
        |> Keyword.merge(config.options)
        |> Keyword.put(:verify, :verify_peer)

      options
      |> Keyword.merge(
        body: body,
        headers: headers,
        decode_body: false,
        retry: false,
        redirect: false,
        tls_backend: if(config.backend == :ex_ssl, do: :ex_ssl, else: :ssl),
        ssl: ssl,
        max_body_bytes: @max_body_bytes,
        max_header_bytes: @max_header_bytes,
        max_header_count: @max_header_count,
        require_identity_encoding: true
      )
      |> HTTPClient.request()
      |> normalize_timeout()
    else
      {:error, {:http, reason}} -> error(reason)
      {:error, reason} -> error(reason)
    end
  rescue
    _ in [ArgumentError, ErlangError, RuntimeError, KeyError] -> error(:invalid_http_request)
  end

  defp validate_request_policy(options, %TLS.Config{backend: :ex_ssl, options: tls_options}) do
    with true <- Keyword.keyword?(options),
         {:ok, false} <- Keyword.fetch(options, :decode_body),
         :ok <- validate_http1_profile(tls_options) do
      :ok
    else
      _ -> {:error, :unsafe_request_policy}
    end
  end

  defp validate_request_policy(options, %TLS.Config{backend: :otp}) do
    if Keyword.keyword?(options), do: :ok, else: {:error, :invalid_http_request}
  end

  defp normalize_timeout({:error, %TransportError{reason: reason} = error})
       when reason in [:request_timeout, :connect_timeout],
       do: {:error, %{error | reason: :timeout}}

  defp normalize_timeout(result), do: result

  defp error(reason),
    do: {:error, %TransportError{reason: reason, phase: :pre_transmission}}

  defp validate_endpoint(%URI{scheme: "https", host: host} = uri)
       when is_binary(host) and host != "" and is_nil(uri.userinfo) and is_nil(uri.fragment) do
    port = uri.port || 443

    if is_integer(port) and port in 1..65_535 do
      {:ok, %{host: host, port: port, target: request_target(uri)}}
    else
      {:error, {:http, :invalid_url}}
    end
  end

  defp validate_endpoint(_uri), do: {:error, {:http, :https_required}}

  defp request_target(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if is_binary(uri.query), do: path <> "?" <> uri.query, else: path
  end

  defp timeout(options, :connect_options, default) do
    connect_options = Map.get(options, :connect_options, [])

    with true <- Keyword.keyword?(connect_options),
         true <- unique_keys?(connect_options),
         [] <- Keyword.keys(connect_options) -- [:timeout, :protocols],
         [:http1] <- Keyword.get(connect_options, :protocols, [:http1]) do
      valid_timeout(Keyword.get(connect_options, :timeout, default))
    else
      _ -> {:error, {:http, :unsupported_connect_options}}
    end
  end

  defp timeout(options, name, default), do: valid_timeout(Map.get(options, name, default))

  defp unique_keys?(options) do
    keys = Keyword.keys(options)
    length(keys) == length(Enum.uniq(keys))
  end

  defp validate_http1_profile(tls_options) do
    with true <- Keyword.keyword?(tls_options),
         true <- unique_keys?(tls_options),
         ex_ssl <- Keyword.get(tls_options, :ex_ssl, []),
         true <- Keyword.keyword?(ex_ssl),
         true <- unique_keys?(ex_ssl),
         [] <- Keyword.keys(ex_ssl) -- [:profile] do
      case Keyword.get(ex_ssl, :profile, :default) do
        :default -> :ok
        %SSL.ClientHello.WireProfile{extensions: extensions} -> validate_profile_alpn(extensions)
        _ -> {:error, :unsupported_profile}
      end
    else
      _ -> {:error, :unsupported_profile}
    end
  end

  defp validate_profile_alpn(extensions) when is_list(extensions) do
    case for({:alpn, protocols} <- extensions, do: protocols) do
      [] -> :ok
      [["http/1.1"]] -> :ok
      _ -> {:error, :unsupported_alpn}
    end
  end

  defp validate_profile_alpn(_extensions), do: {:error, :unsupported_profile}

  defp valid_timeout(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp valid_timeout(_value), do: {:error, {:http, :invalid_timeout}}

  defp method(method) when method in [:options, :post],
    do: {:ok, method |> Atom.to_string() |> String.upcase()}

  defp method(_method), do: {:error, {:http, :unsupported_method}}

  defp body(nil), do: {:ok, <<>>}

  defp body(body) when is_binary(body) and byte_size(body) <= @max_body_bytes,
    do: {:ok, body}

  defp body(body) when is_list(body) do
    if :erlang.iolist_size(body) <= @max_body_bytes,
      do: {:ok, IO.iodata_to_binary(body)},
      else: {:error, {:http, :request_body_too_large}}
  rescue
    ArgumentError -> {:error, {:http, :unsupported_request_body}}
  end

  defp body(_body), do: {:error, {:http, :unsupported_request_body}}

  defp request_headers(options, endpoint, method, body) do
    with :ok <- validate_request_target(endpoint.target),
         {:ok, headers} <- request_headers(Keyword.get(options, :headers, [])),
         :ok <- reject_request_transfer_encoding(headers),
         {:ok, headers} <- put_content_length(headers, byte_size(body)),
         headers <- put_header(headers, "host", host_header(endpoint)),
         headers <- put_default_header(headers, "content-type", "application/octet-stream"),
         headers <- put_header(headers, "connection", "close"),
         headers <-
           put_header(headers, "user-agent", Keyword.get(options, :user_agent, "Manifold EAS")) do
      request_line = [method, " ", endpoint.target, " HTTP/1.1\r\n"]
      encoded_headers = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
      encoded_head = [request_line, encoded_headers, "\r\n"]

      if length(headers) <= @max_header_count and
           :erlang.iolist_size(encoded_head) <= @max_header_bytes,
         do: {:ok, headers},
         else: {:error, {:http, :request_headers_too_large}}
    end
  end

  defp request_headers(fields) do
    headers =
      Enum.flat_map(fields, fn {name, values} ->
        Enum.map(List.wrap(values), &{name, &1})
      end)

    encoded_size =
      Enum.reduce(headers, 0, fn {name, value}, size ->
        size + byte_size(name) + byte_size(value) + 4
      end)

    if length(headers) <= @max_header_count and encoded_size <= @max_header_bytes and
         Enum.all?(headers, &valid_header?/1) do
      {:ok, Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)}
    else
      {:error, {:http, :invalid_request_headers}}
    end
  end

  defp valid_header?({name, value}) when is_binary(name) and is_binary(value) do
    valid_header_name?(name) and
      Enum.all?(:binary.bin_to_list(value), &valid_header_value_byte?/1)
  end

  defp valid_header?(_header), do: false

  defp valid_header_name?(name) when is_binary(name) and name != <<>> do
    Enum.all?(:binary.bin_to_list(name), fn byte ->
      byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z or
        byte in [?!, ?#, ?$, ?%, ?&, ?', ?*, ?+, ?-, ?., ?^, ?_, ?`, ?|, ?~]
    end)
  end

  defp valid_header_name?(_name), do: false

  defp valid_header_value_byte?(byte), do: byte == ?\t or byte in 32..126 or byte in 128..255

  defp validate_request_target(target) do
    if String.starts_with?(target, "/") and
         not String.contains?(target, ["\r", "\n", " ", "\t", <<0>>]),
       do: :ok,
       else: {:error, {:http, :invalid_request_target}}
  end

  defp reject_request_transfer_encoding(headers) do
    if Enum.any?(headers, fn {name, _} -> name == "transfer-encoding" end),
      do: {:error, {:http, :unsupported_request_transfer_encoding}},
      else: :ok
  end

  defp put_content_length(headers, size) do
    values = for {"content-length", value} <- headers, do: value

    if values == [] or Enum.all?(values, &(&1 == Integer.to_string(size))) do
      {:ok, put_header(headers, "content-length", Integer.to_string(size))}
    else
      {:error, {:http, :invalid_request_content_length}}
    end
  end

  defp put_header(headers, name, value) do
    [{name, value} | Enum.reject(headers, fn {header, _} -> header == name end)]
  end

  defp put_default_header(headers, name, value) do
    if Enum.any?(headers, &(elem(&1, 0) == name)), do: headers, else: [{name, value} | headers]
  end

  defp host_header(%{host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    if port == 443, do: host, else: "#{host}:#{port}"
  end
end
