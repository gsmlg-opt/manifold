defmodule Manifold.Core.HTTPClient do
  @moduledoc """
  Native Fetch client for application HTTP requests.

  Requests use fresh HTTP/1 connections, manual redirects, disabled telemetry and
  no transport retries. JSON and form encoding belongs to this small boundary;
  response bytes remain raw until optional JSON decoding. Body limits count raw
  bytes. Streaming responses are single-use enumerables with acknowledged chunks.
  Cleanup uses Fetch's logical completion barrier where supported; that barrier
  does not certify native memory reclamation.
  """
  alias __MODULE__.{Response, TransportError}

  @options ~w(method url headers body json form params auth user_agent decode_body compressed retry redirect receive_timeout connect_options pool_timeout tls_backend ssl plug max_body_bytes retain_body_bytes stream_response max_header_bytes max_header_count require_identity_encoding)a
  @default_limit 64 * 1024 * 1024

  @doc "Cancels an unconsumed or partially consumed streamed response."
  def cancel(%Response{private: %{cancel: cancel}}), do: cancel.()
  def cancel(%Response{}), do: :ok

  def post(options), do: request(Keyword.put(options, :method, :post))

  def request(options) when is_list(options) do
    with :ok <- validate(options),
         {:ok, prepared} <- prepare(options) do
      case prepared.plug do
        nil -> native_request(prepared)
        plug -> test_request(prepared, plug)
      end
    end
  end

  def request(_), do: failure(:invalid_options, :pre_transmission)

  def format_http_date(%DateTime{} = date),
    do: Calendar.strftime(date, "%a, %d %b %Y %H:%M:%S GMT")

  def parse_http_date(value) when is_binary(value) do
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

    with [_, day, month, year, hour, minute, second] <-
           Regex.run(
             ~r/\A(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), ([0-9]{2}) ([A-Za-z]{3}) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT\z/,
             value
           ),
         index when is_integer(index) <- Enum.find_index(months, &(&1 == month)),
         {:ok, date} <- Date.new(String.to_integer(year), index + 1, String.to_integer(day)),
         {:ok, time} <-
           Time.new(String.to_integer(hour), String.to_integer(minute), String.to_integer(second)),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, datetime}
    else
      _ -> {:error, :invalid_date}
    end
  end

  def parse_http_date(_), do: {:error, :invalid_date}

  defp validate(options) do
    if Keyword.keyword?(options),
      do: validate_keywords(options),
      else: failure(:invalid_options, :pre_transmission)
  end

  defp validate_keywords(options) do
    connection = Keyword.get(options, :connect_options, [])

    valid? =
      Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in @options)) and
        Keyword.get(options, :retry, false) == false and
        Keyword.get(options, :redirect, false) == false and
        Keyword.get(options, :compressed, false) == false and
        is_boolean(Keyword.get(options, :decode_body, true)) and
        is_boolean(Keyword.get(options, :stream_response, false)) and
        is_boolean(Keyword.get(options, :require_identity_encoding, false)) and
        Keyword.get(options, :tls_backend, :ssl) in [:ssl, :ex_ssl] and
        Keyword.keyword?(Keyword.get(options, :ssl, [])) and
        Keyword.keyword?(connection) and
        Enum.all?(Keyword.keys(connection), &(&1 in [:timeout, :protocols])) and
        Keyword.get(connection, :protocols, [:http1]) == [:http1] and
        timeout?(Keyword.get(options, :receive_timeout, 15_000)) and
        timeout?(Keyword.get(connection, :timeout, 15_000)) and
        timeout?(Keyword.get(options, :pool_timeout, 15_000)) and
        limit?(Keyword.get(options, :max_body_bytes, @default_limit)) and
        limit?(Keyword.get(options, :retain_body_bytes, :infinity)) and
        positive?(Keyword.get(options, :max_header_bytes, 64 * 1024)) and
        positive?(Keyword.get(options, :max_header_count, 1_000)) and
        Enum.count([:body, :json, :form], &Keyword.has_key?(options, &1)) <= 1

    if valid?, do: :ok, else: failure(:invalid_options, :pre_transmission)
  end

  defp timeout?(n), do: is_integer(n) and n >= 0
  defp positive?(n), do: is_integer(n) and n > 0
  defp limit?(:infinity), do: true
  defp limit?(n), do: is_integer(n) and n >= 0

  defp prepare(options) do
    uri = options |> Keyword.fetch!(:url) |> URI.parse()

    true =
      uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
        uri.userinfo == nil and uri.fragment == nil

    true = not Regex.match?(~r/[\x00-\x20\x7f]/, (uri.path || "") <> (uri.query || ""))
    method = Keyword.get(options, :method, :get)

    true = method not in [nil, true, false]
    _ = HTTP.Request.method_token(method)

    uri = add_params(uri, Keyword.get(options, :params))
    headers = normalize_request_headers(Keyword.get(options, :headers, []))
    {body, headers} = encode_body(options, headers)
    headers = authorize(headers, Keyword.get(options, :auth))

    headers =
      case Keyword.get(options, :user_agent) do
        nil -> headers
        agent when is_binary(agent) -> put_header(headers, "user-agent", agent)
      end

    body = IO.iodata_to_binary(body || "")
    # Validate the exact wire request before allocating tasks or a controller.
    _ =
      HTTP.Request.to_iodata(%HTTP.Request{
        method: method,
        url: uri,
        headers: HTTP.Headers.new(headers),
        body: body,
        request_mode: :proxy
      })

    {:ok,
     %{
       method: Keyword.get(options, :method, :get),
       url: URI.to_string(uri),
       headers: headers,
       body: body,
       timeout: Keyword.get(options, :receive_timeout, 15_000),
       connect_timeout: Keyword.get(Keyword.get(options, :connect_options, []), :timeout, 15_000),
       send_timeout: Keyword.get(options, :pool_timeout, 15_000),
       tls_backend: Keyword.get(options, :tls_backend, :ssl),
       ssl: Keyword.get(options, :ssl, []),
       decode_body: Keyword.get(options, :decode_body, true),
       require_identity_encoding: Keyword.get(options, :require_identity_encoding, false),
       plug: Keyword.get(options, :plug),
       max_bytes: Keyword.get(options, :max_body_bytes, @default_limit),
       max_header_bytes: Keyword.get(options, :max_header_bytes, 64 * 1024),
       max_header_count: Keyword.get(options, :max_header_count, 1_000),
       retain_bytes: Keyword.get(options, :retain_body_bytes, :infinity),
       stream?: Keyword.get(options, :stream_response, false)
     }}
  rescue
    _ -> failure(:invalid_options, :pre_transmission)
  end

  defp add_params(uri, nil), do: uri

  defp add_params(uri, params) do
    query = URI.encode_query(params)
    %{uri | query: Enum.reject([uri.query, query], &(&1 in [nil, ""])) |> Enum.join("&")}
  end

  defp normalize_request_headers(headers) do
    Enum.flat_map(headers, fn {name, values} ->
      Enum.map(List.wrap(values), &{String.downcase(to_string(name)), to_string(&1)})
    end)
  end

  defp put_header(headers, name, value),
    do: [{name, value} | Enum.reject(headers, &(elem(&1, 0) == name))]

  defp encode_body(options, headers) do
    cond do
      Keyword.has_key?(options, :json) ->
        {Jason.encode!(options[:json]), put_header(headers, "content-type", "application/json")}

      Keyword.has_key?(options, :form) ->
        {URI.encode_query(options[:form]),
         put_header(headers, "content-type", "application/x-www-form-urlencoded")}

      true ->
        {Keyword.get(options, :body, ""), headers}
    end
  end

  defp authorize(headers, nil), do: headers

  defp authorize(headers, {:bearer, token}) when is_binary(token),
    do: put_header(headers, "authorization", "Bearer " <> token)

  defp authorize(headers, {:basic, credentials}) when is_binary(credentials),
    do: put_header(headers, "authorization", "Basic " <> Base.encode64(credentials))

  defp native_request(prepared) do
    controller = HTTP.AbortController.new()
    Process.unlink(controller)

    guardian =
      watch_caller(controller, System.monotonic_time(:millisecond) + prepared.timeout + 1_000)

    result =
      try do
        fetch_request(prepared, controller, guardian)
      rescue
        _ ->
          stop_controller(controller)
          failure(:transport_failure)
      catch
        :exit, _ ->
          stop_controller(controller)
          failure(:transport_failure)
      end

    send(guardian, :handoff)
    result
  end

  defp watch_caller(controller, deadline) do
    caller = self()

    {:ok, guardian} =
      Task.start(fn ->
        caller_monitor = Process.monitor(caller)
        controller_monitor = Process.monitor(controller)
        caller_loop(controller, caller_monitor, controller_monitor, deadline, nil)
      end)

    guardian
  end

  defp caller_loop(controller, caller_monitor, controller_monitor, deadline, context) do
    receive do
      {:request_context, next} ->
        caller_loop(controller, caller_monitor, controller_monitor, deadline, next)

      :handoff ->
        if caller_monitor, do: Process.demonitor(caller_monitor, [:flush])
        caller_loop(controller, nil, controller_monitor, deadline, context)

      {:DOWN, ^controller_monitor, :process, ^controller, _} ->
        if caller_monitor, do: Process.demonitor(caller_monitor, [:flush])
        :ok

      {:DOWN, monitor, :process, _, _} when monitor == caller_monitor ->
        abort_controller(controller)

        if context do
          _ = cleanup(context, true)
          Process.demonitor(controller_monitor, [:flush])
        else
          # Cancellation before the Promise handle is delivered still reaches
          # a subsequently admitted owner through the aborted signal.
          caller_loop(controller, nil, controller_monitor, deadline, nil)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        abort_controller(controller)
        if context, do: cleanup(context, true), else: close_controller(controller)
        if caller_monitor, do: Process.demonitor(caller_monitor, [:flush])
        Process.demonitor(controller_monitor, [:flush])
    end
  end

  defp fetch_request(prepared, controller, guardian) do
    promise =
      HTTP.fetch(prepared.url,
        signal: controller,
        method: prepared.method,
        body: prepared.body,
        headers: prepared.headers,
        http_version: :http1,
        http1_reuse: false,
        redirect: :manual,
        request_mode: :proxy,
        telemetry: false,
        decode_body: false,
        stream_response: true,
        error_mode: :structured,
        timeout: prepared.timeout,
        connect_timeout: prepared.connect_timeout,
        socket_opts: [send_timeout: prepared.send_timeout, send_timeout_close: true],
        tls_backend: prepared.tls_backend,
        ssl: prepared.ssl
      )

    completion = {HTTP.Promise.completion(promise), controller, nil}
    send(guardian, {:request_context, completion})
    deadline = System.monotonic_time(:millisecond) + prepared.timeout

    try do
      case HTTP.Promise.await(promise) do
        %HTTP.Response{} = response ->
          normalized = %Response{
            status: response.status,
            headers: header_map(response.headers),
            trailers: header_map(response.trailers)
          }

          send(
            guardian,
            {:request_context,
             put_elem(completion, 2, if(is_pid(response.body), do: response.body))}
          )

          if reason = response_policy_error(normalized, prepared) do
            _ =
              cleanup(put_elem(completion, 2, if(is_pid(response.body), do: response.body)), true)

            failure(reason)
          else
            if is_pid(response.body) do
              trailers_ref = make_ref()
              context = put_elem(completion, 2, response.body)
              guard = guard_stream(context, deadline)

              stream =
                enumerable(
                  response.body,
                  {context, guard},
                  deadline,
                  prepared.max_bytes,
                  fn trailers ->
                    trailers = header_map(trailers)
                    combined = Map.merge(normalized.headers, trailers, fn _, a, b -> a ++ b end)

                    if not headers_allowed?(combined, prepared),
                      do: raise(TransportError, reason: :header_limit)

                    if not prepared.stream?, do: Process.put(trailers_ref, trailers)
                  end
                )

              if prepared.stream? do
                {:ok,
                 %{
                   normalized
                   | body: stream,
                     private: %{streaming: true, cancel: fn -> cancel_stream(context, guard) end}
                 }}
              else
                collect(normalized, stream, prepared, trailers_ref)
              end
            else
              case cleanup(completion, false) do
                :ok -> buffered(normalized, response.body || "", prepared)
                {:error, reason} -> failure(reason)
              end
            end
          end

        {:error, %HTTP.RequestError{} = error} ->
          _ = cleanup(completion, true)

          failure(
            safe_reason(error.reason),
            if(HTTP.RequestError.pre_send?(error), do: :pre_transmission, else: :unknown)
          )

        {:error, _} ->
          _ = cleanup(completion, true)
          failure(:transport_failure)
      end
    rescue
      _ ->
        _ = cleanup(completion, true)
        failure(:transport_failure)
    catch
      :exit, _ ->
        _ = cleanup(completion, true)
        failure(:transport_failure)
    end
  end

  defp stop_controller(controller) do
    if Process.alive?(controller) do
      HTTP.AbortController.abort(controller)
      Agent.stop(controller)
    end
  end

  defp header_map(nil), do: %{}
  defp header_map(%HTTP.Headers{headers: fields}), do: header_map(fields)

  defp header_map(fields),
    do:
      Enum.reduce(fields, %{}, fn {name, value}, acc ->
        Map.update(acc, String.downcase(name), [value], &(&1 ++ [value]))
      end)

  defp guard_stream({_completion, _controller, stream} = context, deadline) do
    {:ok, guard} =
      Task.start(fn ->
        monitor = Process.monitor(stream)

        receive do
          {:DOWN, ^monitor, :process, ^stream, _} -> :ok
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            _ = cleanup(context, true)
        end

        {_completion, controller, _stream} = context
        close_controller(controller)
      end)

    guard
  end

  defp cancel_stream(context, guard) do
    result = cleanup(context, true)
    with :ok <- result, :ok <- await_process_end(guard), do: :ok
  end

  defp enumerable(stream, completion, deadline, max_bytes, on_trailers) do
    Stream.resource(
      fn ->
        monitor = Process.monitor(stream)
        send(stream, {:read_chunk, self(), :ack})

        %{
          stream: stream,
          completion: completion,
          deadline: deadline,
          monitor: monitor,
          ack: nil,
          bytes: 0,
          done?: false,
          on_trailers: on_trailers
        }
      end,
      fn state -> next_chunk(state, max_bytes) end,
      fn state ->
        Process.demonitor(state.monitor, [:flush])

        case cleanup(state.completion, not state.done?) do
          :ok -> :ok
          {:error, reason} -> raise TransportError, reason: reason
        end

        flush_stream(state.stream)
      end
    )
  end

  defp next_chunk(state, max_bytes) do
    if state.ack, do: send(state.stream, {:stream_chunk_ack, state.ack})
    remaining = max(state.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:stream_chunk, stream, chunk, ack} when stream == state.stream ->
        bytes = state.bytes + byte_size(chunk)

        if max_bytes != :infinity and bytes > max_bytes,
          do: raise(TransportError, reason: :response_limit)

        {[chunk], %{state | bytes: bytes, ack: ack}}

      {:stream_chunk, stream, chunk} when stream == state.stream ->
        bytes = state.bytes + byte_size(chunk)

        if max_bytes != :infinity and bytes > max_bytes,
          do: raise(TransportError, reason: :response_limit)

        {[chunk], %{state | bytes: bytes, ack: nil}}

      {:stream_trailers, stream, trailers} when stream == state.stream ->
        state.on_trailers.(trailers)
        next_chunk(%{state | ack: nil}, max_bytes)

      {:stream_end, stream} when stream == state.stream ->
        {:halt, %{state | done?: true, ack: nil}}

      {:stream_error, stream, reason} when stream == state.stream ->
        raise TransportError, reason: safe_reason(reason)

      {:DOWN, monitor, :process, stream, _}
      when monitor == state.monitor and stream == state.stream ->
        # The stream sends its terminal message before exiting.
        receive do
          {:stream_end, ^stream} -> {:halt, %{state | done?: true, ack: nil}}
          {:stream_error, ^stream, reason} -> raise TransportError, reason: safe_reason(reason)
        after
          0 -> raise TransportError, reason: :closed
        end
    after
      remaining -> raise TransportError, reason: :timeout
    end
  end

  defp cleanup({context, guard}, abort?) do
    with :ok <- cleanup(context, abort?), :ok <- await_process_end(guard), do: :ok
  end

  defp cleanup({completion, controller, stream}, abort?) do
    if abort? do
      abort_controller(controller)

      if is_pid(stream) do
        send(stream, {:read_chunk, self(), :ack})
        HTTP.Stream.error(stream, :aborted)
      end
    end

    result =
      case completion do
        %HTTP.RequestCompletion{unsupported: nil} ->
          if abort?,
            do: HTTP.RequestCompletion.abort_and_await(completion, 5_000),
            else: HTTP.RequestCompletion.await(completion, 5_000)

        %HTTP.RequestCompletion{unsupported: :tls_backend} ->
          await_stream_end(stream)
      end

    close_controller(controller)
    result
  end

  defp abort_controller(controller) do
    if Process.alive?(controller), do: HTTP.AbortController.abort(controller)
  catch
    :exit, _ -> :ok
  end

  defp close_controller(controller) do
    if Process.alive?(controller), do: Agent.stop(controller)
  catch
    :exit, _ -> :ok
  end

  defp await_stream_end(nil), do: :ok
  defp await_stream_end(stream), do: await_process_end(stream)

  defp await_process_end(stream) do
    monitor = Process.monitor(stream)

    receive do
      {:DOWN, ^monitor, :process, ^stream, _} -> :ok
    after
      5_000 ->
        Process.demonitor(monitor, [:flush])
        {:error, :cleanup_pending}
    end
  end

  defp flush_stream(stream) do
    receive do
      {:stream_chunk, ^stream, _, _} -> flush_stream(stream)
      {:stream_chunk, ^stream, _} -> flush_stream(stream)
      {:stream_end, ^stream} -> flush_stream(stream)
      {:stream_error, ^stream, _} -> flush_stream(stream)
      {:stream_trailers, ^stream, _} -> flush_stream(stream)
    after
      0 -> :ok
    end
  end

  defp collect(response, stream, prepared, trailers_ref) do
    {chunks, size} =
      Enum.reduce(stream, {[], 0}, fn chunk, {chunks, size} ->
        retain =
          if prepared.retain_bytes == :infinity,
            do: byte_size(chunk),
            else: min(byte_size(chunk), max(prepared.retain_bytes - size, 0))

        chunks = if retain > 0, do: [binary_part(chunk, 0, retain) | chunks], else: chunks
        {chunks, size + byte_size(chunk)}
      end)

    response = %{response | trailers: Process.get(trailers_ref, response.trailers)}
    finish_body(response, chunks |> Enum.reverse() |> IO.iodata_to_binary(), size, prepared)
  rescue
    error in TransportError -> {:error, error}
  after
    Process.delete(trailers_ref)
  end

  defp response_policy_error(response, prepared) do
    cond do
      not headers_allowed?(response.headers, prepared) ->
        :header_limit

      prepared.require_identity_encoding and not identity_encoding?(response.headers) ->
        :unsupported_content_encoding

      declared_body_exceeds_limit?(response, prepared) ->
        :response_limit

      true ->
        nil
    end
  end

  defp identity_encoding?(headers) do
    headers
    |> Map.get("content-encoding", [])
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.all?(&(String.trim(&1) |> String.downcase() == "identity"))
  end

  defp declared_body_exceeds_limit?(response, prepared) do
    if prepared.max_bytes == :infinity or prepared.method in [:head, "HEAD"] or
         response.status in [204, 304] do
      false
    else
      Enum.any?(Map.get(response.headers, "content-length", []), fn value ->
        case Integer.parse(value) do
          {size, ""} -> size > prepared.max_bytes
          _ -> false
        end
      end)
    end
  end

  defp headers_allowed?(headers, prepared) do
    fields = Enum.flat_map(headers, fn {name, values} -> Enum.map(values, &{name, &1}) end)

    length(fields) <= prepared.max_header_count and
      Enum.reduce(fields, 0, fn {name, value}, count ->
        count + byte_size(name) + byte_size(value)
      end) <= prepared.max_header_bytes
  end

  defp buffered(response, body, prepared) do
    size = byte_size(body)

    if reason = response_policy_error(response, prepared) do
      failure(reason)
    else
      if prepared.max_bytes != :infinity and size > prepared.max_bytes do
        failure(:response_limit)
      else
        retained =
          if prepared.retain_bytes == :infinity,
            do: body,
            else: binary_part(body, 0, min(size, prepared.retain_bytes))

        finish_body(response, retained, size, prepared)
      end
    end
  end

  defp finish_body(response, body, size, prepared) do
    decoded =
      if prepared.decode_body,
        do: __MODULE__.ContentDecoder.decode(response.headers, body, prepared.max_bytes),
        else: {:ok, body, response.headers}

    case decoded do
      {:ok, bytes, headers} ->
        body =
          if prepared.decode_body and json_content?(headers), do: decode_json(bytes), else: bytes

        {:ok,
         %{
           response
           | body: body,
             headers: headers,
             private: Map.put(response.private, :raw_body_size, size)
         }}

      {:error, reason} ->
        failure(reason)
    end
  end

  defp json_content?(headers),
    do:
      Enum.any?(
        Map.get(headers, "content-type", []),
        &(String.contains?(&1, "application/json") or String.contains?(&1, "+json"))
      )

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, data} -> data
      {:error, _} -> body
    end
  end

  defp test_request(prepared, plug) do
    module = Module.concat(__MODULE__, Test)

    if Code.ensure_loaded?(module) do
      case module.request(prepared.method, prepared.url, prepared.headers, prepared.body, plug) do
        {:ok, %{status: status, headers: headers, body: body}} ->
          buffered(%Response{status: status, headers: header_map(headers)}, body, prepared)

        {:error, reason} ->
          {:error, reason}
      end
    else
      failure(:invalid_options, :pre_transmission)
    end
  end

  defp safe_reason(:unexpected_eof), do: :closed

  defp safe_reason(reason)
       when reason in [
              :timeout,
              :request_timeout,
              :connect_timeout,
              :closed,
              :econnrefused,
              :nxdomain,
              :econnreset,
              :enetunreach,
              :ehostunreach,
              :aborted,
              :response_limit,
              :headers_too_large,
              :invalid_http_response,
              :content_length_mismatch,
              :conflicting_response_framing,
              :invalid_content_length,
              :invalid_status_line,
              :invalid_header,
              :invalid_chunk,
              :invalid_chunk_size,
              :invalid_transfer_encoding,
              :unsupported_protocol_switch,
              :line_too_long,
              :trailers_too_large,
              :invalid_trailer,
              :forbidden_trailer
            ],
       do: reason

  defp safe_reason(_), do: :transport_failure

  defp failure(reason, phase \\ :unknown),
    do: {:error, %TransportError{reason: reason, phase: phase}}
end
