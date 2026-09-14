defmodule Manifold.Connectors.EAS.HTTPAdapter do
  @moduledoc false

  alias Manifold.Connectors.TLS

  @tls_private :manifold_eas_tls_config
  @max_header_bytes 64 * 1024
  @max_header_count 200
  @max_body_bytes 64 * 1024 * 1024
  @max_chunk_line_bytes 1024
  # TODO(upstream): gsmlg-dev/ex_ssl#3 - fixed in pinned cddd844; retain the max-bound regression.
  @max_tls_read_bytes 1024 * 1024

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

  @spec put_tls_config(Req.Request.t(), TLS.Config.t()) :: Req.Request.t()
  def put_tls_config(%Req.Request{} = request, %TLS.Config{} = config) do
    Req.Request.put_private(request, @tls_private, config)
  end

  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    case request(request) do
      {:ok, response} ->
        {request, response}

      {:error, {:http, reason}} ->
        {request, %Req.HTTPError{protocol: :http1, reason: reason}}

      {:error, reason} ->
        {request, %Req.TransportError{reason: normalize_transport_reason(reason)}}
    end
  end

  defp request(request) do
    with {:ok, config} <- fetch_config(request),
         :ok <- validate_adapter_request(request, config),
         {:ok, endpoint} <- validate_endpoint(request.url),
         {:ok, timeout} <- timeout(request.options, :connect_options, 15_000),
         {:ok, receive_timeout} <- timeout(request.options, :receive_timeout, 60_000),
         {:ok, method} <- method(request.method),
         {:ok, body} <- body(request.body),
         {:ok, encoded_request} <- encode_request(request, endpoint, method, body),
         {:ok, socket} <- connect(endpoint, config, timeout) do
      try do
        exchange(socket, request.method, encoded_request, receive_timeout)
      after
        _ = TLS.close(socket)
      end
    end
  end

  defp validate_adapter_request(%Req.Request{into: nil, options: options}, config) do
    with {:ok, false} <- Map.fetch(options, :decode_body),
         false <- Map.get(options, :retry),
         false <- Map.get(options, :redirect),
         :ok <- validate_http1_profile(config.options) do
      :ok
    else
      _ -> {:error, {:http, :unsafe_request_policy}}
    end
  end

  defp validate_adapter_request(_request, _config),
    do: {:error, {:http, :unsupported_response_streaming}}

  defp fetch_config(request) do
    case Req.Request.get_private(request, @tls_private) do
      %TLS.Config{backend: :ex_ssl} = config -> {:ok, config}
      _ -> {:error, {:http, :missing_tls_config}}
    end
  end

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

  defp valid_timeout(:infinity), do: {:ok, :infinity}
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

  defp encode_request(request, endpoint, method, body) do
    with :ok <- validate_request_target(endpoint.target),
         {:ok, headers} <- request_headers(request.headers),
         :ok <- reject_request_transfer_encoding(headers),
         {:ok, headers} <- put_content_length(headers, byte_size(body)),
         headers <- put_header(headers, "host", host_header(endpoint)),
         headers <- put_header(headers, "connection", "close") do
      request_line = [method, " ", endpoint.target, " HTTP/1.1\r\n"]
      encoded_headers = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
      encoded_head = [request_line, encoded_headers, "\r\n"]

      if length(headers) <= @max_header_count and
           :erlang.iolist_size(encoded_head) <= @max_header_bytes,
         do: {:ok, [encoded_head, body]},
         else: {:error, {:http, :request_headers_too_large}}
    end
  end

  defp request_headers(fields) do
    headers = Req.Fields.get_list(fields)

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

  defp host_header(%{host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    if port == 443, do: host, else: "#{host}:#{port}"
  end

  defp connect(endpoint, config, timeout) do
    options = [
      :binary,
      active: false,
      packet: :raw,
      verify: :verify_peer,
      server_name_indication: String.to_charlist(endpoint.host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      versions: [:"tlsv1.3"]
    ]

    TLS.connect(endpoint.host, endpoint.port, options, timeout, config)
  end

  defp exchange(socket, method, request, receive_timeout) do
    deadline = deadline(receive_timeout)

    with :ok <- TLS.send(socket, request),
         {:ok, status, headers, rest} <- read_head(socket, deadline, <<>>),
         {:ok, body, trailers} <- read_body(socket, method, status, headers, rest, deadline) do
      {:ok, Req.Response.new(status: status, headers: headers, body: body, trailers: trailers)}
    end
  end

  defp read_head(socket, deadline, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, 4} when index <= @max_header_bytes ->
        <<head::binary-size(index), _separator::binary-size(4), rest::binary>> = buffer
        parse_head(head, rest)

      {_, 4} ->
        {:error, {:http, :headers_too_large}}

      :nomatch ->
        if byte_size(buffer) > @max_header_bytes do
          {:error, {:http, :headers_too_large}}
        else
          with {:ok, bytes} <- recv(socket, deadline),
               false <- bytes == <<>> do
            read_head(socket, deadline, buffer <> bytes)
          else
            true -> {:error, {:http, :empty_response_fragment}}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp parse_head(head, rest) do
    case :binary.split(head, "\r\n", [:global]) do
      [status_line | header_lines] when length(header_lines) <= @max_header_count ->
        with {:ok, status} <- parse_status(status_line),
             {:ok, headers} <- parse_headers(header_lines) do
          if status in 100..199,
            do: {:error, {:http, :unsupported_informational_response}},
            else: {:ok, status, headers, rest}
        end

      _ ->
        {:error, {:http, :too_many_headers}}
    end
  end

  defp parse_status(<<"HTTP/1.", minor, " ", code::binary-size(3), rest::binary>>)
       when minor in [?0, ?1] do
    with {status, ""} <- Integer.parse(code),
         true <- status in 100..599,
         true <- rest == <<>> or match?(<<" ", _::binary>>, rest),
         false <- String.contains?(rest, ["\r", "\n", <<0>>]) do
      {:ok, status}
    else
      _ -> {:error, {:http, :invalid_status_line}}
    end
  end

  defp parse_status(_line), do: {:error, {:http, :invalid_status_line}}

  defp parse_headers(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, headers} ->
      case :binary.split(line, ":") do
        [name, value] ->
          name = String.downcase(name)
          value = trim_ows(value)

          if valid_header?({name, value}) and not String.starts_with?(line, [" ", "\t"]) do
            {:cont, {:ok, [{name, value} | headers]}}
          else
            {:halt, {:error, {:http, :invalid_response_header}}}
          end

        _ ->
          {:halt, {:error, {:http, :invalid_response_header}}}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      error -> error
    end
  end

  defp trim_ows(value), do: value |> trim_ows_leading() |> trim_ows_trailing()

  defp trim_ows_leading(<<byte, rest::binary>>) when byte in [?\s, ?\t],
    do: trim_ows_leading(rest)

  defp trim_ows_leading(value), do: value

  defp trim_ows_trailing(<<>>), do: <<>>

  defp trim_ows_trailing(value) when byte_size(value) > 0 do
    case value do
      <<rest::binary-size(byte_size(value) - 1), byte>> when byte in [?\s, ?\t] ->
        trim_ows_trailing(rest)

      _ ->
        value
    end
  end

  defp read_body(_socket, method, status, _headers, rest, _deadline)
       when method == :head or status in 100..199 or status in [204, 304] do
    if rest == <<>>, do: {:ok, <<>>, []}, else: {:error, {:http, :unexpected_response_body}}
  end

  defp read_body(socket, _method, _status, headers, rest, deadline) do
    transfer_encoding = header_tokens(headers, "transfer-encoding")
    content_lengths = header_values(headers, "content-length")
    content_encoding = header_tokens(headers, "content-encoding")

    cond do
      content_encoding not in [[], ["identity"]] ->
        {:error, {:http, :unsupported_content_encoding}}

      transfer_encoding != [] and content_lengths != [] ->
        {:error, {:http, :conflicting_response_framing}}

      transfer_encoding == ["chunked"] ->
        read_chunks(socket, deadline, rest, [], 0, [])

      transfer_encoding != [] ->
        {:error, {:http, :unsupported_response_transfer_encoding}}

      content_lengths != [] ->
        with {:ok, length} <- content_length(content_lengths) do
          read_exact(socket, deadline, rest, length)
        end

      true ->
        read_until_close(socket, deadline, rest)
    end
  end

  defp header_values(headers, wanted),
    do: for({name, value} <- headers, name == wanted, do: value)

  defp header_tokens(headers, wanted) do
    headers
    |> header_values(wanted)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.downcase(String.trim(&1)))
  end

  defp content_length(values) do
    parsed =
      Enum.map(values, fn value ->
        if value != <<>> and Enum.all?(:binary.bin_to_list(value), &(&1 in ?0..?9)) do
          case Integer.parse(value) do
            {length, ""} when length <= @max_body_bytes -> length
            _ -> :invalid
          end
        else
          :invalid
        end
      end)

    case Enum.uniq(parsed) do
      [length] when is_integer(length) -> {:ok, length}
      _ -> {:error, {:http, :invalid_content_length}}
    end
  end

  defp read_exact(_socket, _deadline, buffer, length) when byte_size(buffer) > length,
    do: {:error, {:http, :data_after_content_length}}

  defp read_exact(_socket, _deadline, buffer, length) when byte_size(buffer) == length,
    do: {:ok, buffer, []}

  defp read_exact(socket, deadline, buffer, length) do
    needed = length - byte_size(buffer)

    with {:ok, bytes} <- recv_exact_bytes(socket, needed, deadline) do
      {:ok, IO.iodata_to_binary([buffer, bytes]), []}
    end
  end

  defp read_until_close(socket, deadline, buffer) do
    read_until_close(socket, deadline, [buffer], byte_size(buffer))
  end

  defp read_until_close(_socket, _deadline, _chunks, size) when size > @max_body_bytes,
    do: {:error, {:http, :response_body_too_large}}

  defp read_until_close(socket, deadline, chunks, size) do
    case recv(socket, deadline) do
      {:ok, bytes} ->
        read_until_close(socket, deadline, [bytes | chunks], size + byte_size(bytes))

      {:error, :closed} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_chunks(socket, deadline, buffer, body, body_size, trailers) do
    with {:ok, line, rest} <- read_line(socket, deadline, buffer, @max_chunk_line_bytes),
         {:ok, size} <- chunk_size(line) do
      if size == 0 do
        read_trailers(socket, deadline, rest, trailers, 0)
        |> case do
          {:ok, parsed_trailers, <<>>} ->
            {:ok, body |> Enum.reverse() |> IO.iodata_to_binary(), parsed_trailers}

          {:ok, _parsed_trailers, _extra} ->
            {:error, {:http, :data_after_chunked_body}}

          error ->
            error
        end
      else
        if body_size + size > @max_body_bytes do
          {:error, {:http, :response_body_too_large}}
        else
          with {:ok, chunk_and_crlf, rest} <- take_bytes(socket, deadline, rest, size + 2),
               <<chunk::binary-size(size), "\r\n">> <- chunk_and_crlf do
            read_chunks(socket, deadline, rest, [chunk | body], body_size + size, trailers)
          else
            {:error, reason} -> {:error, reason}
            _ -> {:error, {:http, :invalid_chunk_terminator}}
          end
        end
      end
    end
  end

  defp chunk_size(line) do
    {value, extensions} = take_while(line, &hex_digit?/1)

    with false <- value == <<>>,
         {size, ""} <- Integer.parse(value, 16),
         :ok <- chunk_extensions(extensions) do
      {:ok, size}
    else
      _ -> {:error, {:http, :invalid_chunk_size}}
    end
  end

  defp hex_digit?(byte), do: byte in ?0..?9 or byte in ?a..?f or byte in ?A..?F

  defp chunk_extensions(<<>>), do: :ok

  defp chunk_extensions(bytes) do
    {_bws, bytes} = take_while(bytes, &bws?/1)

    case bytes do
      <<?;, rest::binary>> -> chunk_extension(rest)
      _ -> {:error, :invalid_chunk_extension}
    end
  end

  defp chunk_extension(bytes) do
    {_bws, bytes} = take_while(bytes, &bws?/1)
    {name, rest} = take_while(bytes, &token_byte?/1)

    if name == <<>>, do: {:error, :invalid_chunk_extension}, else: chunk_extension_value(rest)
  end

  defp chunk_extension_value(<<>>), do: :ok

  defp chunk_extension_value(bytes) do
    {_bws, after_bws} = take_while(bytes, &bws?/1)

    case after_bws do
      <<?=, rest::binary>> -> chunk_extension_value_data(rest)
      <<?;, _rest::binary>> -> chunk_extensions(bytes)
      _ -> {:error, :invalid_chunk_extension}
    end
  end

  defp chunk_extension_value_data(bytes) do
    {_bws, bytes} = take_while(bytes, &bws?/1)

    case bytes do
      <<?\", rest::binary>> ->
        quoted_chunk_extension(rest)

      _ ->
        {value, rest} = take_while(bytes, &token_byte?/1)

        if value == <<>>,
          do: {:error, :invalid_chunk_extension},
          else: chunk_extension_continuation(rest)
    end
  end

  defp quoted_chunk_extension(<<?\", rest::binary>>),
    do: chunk_extension_continuation(rest)

  defp quoted_chunk_extension(<<?\\, byte, rest::binary>>)
       when byte == ?\t or byte == ?\s or byte in 33..126 or byte in 128..255,
       do: quoted_chunk_extension(rest)

  defp quoted_chunk_extension(<<byte, rest::binary>>)
       when byte == ?\t or byte == ?\s or byte == ?! or byte in 35..91 or byte in 93..126 or
              byte in 128..255,
       do: quoted_chunk_extension(rest)

  defp quoted_chunk_extension(_bytes), do: {:error, :invalid_chunk_extension}

  defp chunk_extension_continuation(<<>>), do: :ok

  defp chunk_extension_continuation(bytes) do
    {_bws, after_bws} = take_while(bytes, &bws?/1)

    case after_bws do
      <<?;, _rest::binary>> -> chunk_extensions(bytes)
      _ -> {:error, :invalid_chunk_extension}
    end
  end

  defp take_while(bytes, predicate), do: take_while(bytes, bytes, predicate, 0)

  defp take_while(original, <<byte, rest::binary>> = remaining, predicate, count) do
    if predicate.(byte),
      do: take_while(original, rest, predicate, count + 1),
      else: {binary_part(original, 0, count), remaining}
  end

  defp take_while(original, <<>>, _predicate, _count), do: {original, <<>>}

  defp bws?(byte), do: byte in [?\s, ?\t]
  defp token_byte?(byte), do: valid_header_name?(<<byte>>)

  defp read_trailers(socket, deadline, buffer, trailers, bytes)
       when length(trailers) <= @max_header_count and bytes <= @max_header_bytes do
    with {:ok, line, rest} <- read_line(socket, deadline, buffer, @max_header_bytes) do
      if line == <<>> do
        {:ok, Enum.reverse(trailers), rest}
      else
        case parse_headers([line]) do
          {:ok, [trailer]} ->
            read_trailers(
              socket,
              deadline,
              rest,
              [trailer | trailers],
              bytes + byte_size(line) + 2
            )

          error ->
            error
        end
      end
    end
  end

  defp read_trailers(_socket, _deadline, _buffer, _trailers, _bytes),
    do: {:error, {:http, :too_many_trailers}}

  defp read_line(socket, deadline, buffer, maximum) do
    case :binary.match(buffer, "\r\n") do
      {index, 2} when index <= maximum ->
        <<line::binary-size(index), _crlf::binary-size(2), rest::binary>> = buffer
        {:ok, line, rest}

      {_, 2} ->
        {:error, {:http, :line_too_large}}

      :nomatch ->
        if byte_size(buffer) > maximum do
          {:error, {:http, :line_too_large}}
        else
          with {:ok, bytes} <- recv(socket, deadline) do
            read_line(socket, deadline, buffer <> bytes, maximum)
          end
        end
    end
  end

  defp take_bytes(_socket, _deadline, buffer, count) when byte_size(buffer) >= count do
    <<wanted::binary-size(count), rest::binary>> = buffer
    {:ok, wanted, rest}
  end

  defp take_bytes(socket, deadline, buffer, count) do
    needed = count - byte_size(buffer)

    with {:ok, bytes} <- recv_exact_bytes(socket, needed, deadline) do
      {:ok, IO.iodata_to_binary([buffer, bytes]), <<>>}
    end
  end

  defp recv(socket, deadline) do
    case remaining(deadline) do
      0 -> {:error, :timeout}
      timeout -> TLS.recv(socket, 0, timeout)
    end
  end

  defp recv_exact_bytes(socket, count, deadline) do
    recv_exact_bytes(socket, count, deadline, [])
  end

  defp recv_exact_bytes(_socket, 0, _deadline, chunks) do
    {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp recv_exact_bytes(socket, count, deadline, chunks) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      timeout ->
        length = min(count, @max_tls_read_bytes)

        case TLS.recv(socket, length, timeout) do
          {:ok, bytes} ->
            recv_exact_bytes(socket, count - byte_size(bytes), deadline, [bytes | chunks])

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp normalize_transport_reason({:error, reason}), do: normalize_transport_reason(reason)

  defp normalize_transport_reason(reason) when reason in [:timeout, :closed, :econnreset],
    do: reason

  defp normalize_transport_reason(reason) when is_atom(reason), do: reason
  defp normalize_transport_reason(_reason), do: :protocol_not_negotiated
end
