defmodule Manifold.Connectors.DAV.MintAdapter do
  @moduledoc false

  # Fresh Mint connections keep Basic credentials out of Finch request telemetry.
  def run(request) do
    timeout = Req.Request.get_option(request, :dav_timeout, 15_000)
    max_bytes = Req.Request.get_option(request, :dav_max_body_bytes, 8 * 1024 * 1024)
    task = Task.async(fn -> execute(request, timeout, max_bytes) end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :timeout}
      end

    case result do
      {:ok, response} -> {request, response}
      {:error, reason} -> {request, %Req.TransportError{reason: reason}}
    end
  end

  defp execute(request, timeout, max_bytes) do
    deadline = System.monotonic_time(:millisecond) + timeout

    scheme =
      case request.url.scheme do
        "https" -> :https
        "http" -> :http
      end

    headers =
      Enum.flat_map(request.headers, fn {key, values} ->
        Enum.map(List.wrap(values), &{key, &1})
      end)

    method =
      if is_atom(request.method),
        do: request.method |> Atom.to_string() |> String.upcase(),
        else: request.method

    path =
      (request.url.path || "/") <> if(request.url.query, do: "?" <> request.url.query, else: "")

    case Mint.HTTP.connect(scheme, request.url.host, request.url.port,
           mode: :passive,
           protocols: [:http1],
           max_header_list_size: 64 * 1024,
           transport_opts: [timeout: timeout]
         ) do
      {:ok, connection} ->
        try do
          case Mint.HTTP.request(connection, method, path, headers, request.body) do
            {:ok, connection, ref} ->
              receive_response(connection, ref, deadline, max_bytes, %{
                status: nil,
                headers: [],
                header_bytes: 0,
                chunks: [],
                bytes: 0,
                done: false
              })

            {:error, _, _} ->
              {:error, :transport_failure}
          end
        after
          Mint.HTTP.close(connection)
        end

      {:error, _} ->
        {:error, :transport_failure}
    end
  rescue
    _ -> {:error, :transport_failure}
  end

  defp receive_response(connection, ref, deadline, max_bytes, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case Mint.HTTP.recv(connection, 0, remaining) do
        {:ok, connection, responses} ->
          case accumulate(responses, ref, state, max_bytes) do
            {:ok, %{done: true} = state} ->
              {:ok,
               Req.Response.new(
                 status: state.status,
                 headers: state.headers,
                 body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
               )}

            {:ok, state} ->
              receive_response(connection, ref, deadline, max_bytes, state)

            error ->
              error
          end

        {:error, _, %Mint.HTTPError{reason: {:max_header_list_size_exceeded, _, _}}, _} ->
          {:error, :header_limit}

        {:error, _, %Mint.TransportError{reason: :timeout}, _} ->
          {:error, :timeout}

        {:error, _, _, _} ->
          {:error, :transport_failure}
      end
    end
  end

  defp accumulate(responses, ref, state, max_bytes) do
    Enum.reduce_while(responses, {:ok, state}, fn
      {:status, ^ref, status}, {:ok, state} ->
        {:cont, {:ok, %{state | status: status}}}

      {:headers, ^ref, headers}, {:ok, state} ->
        bytes =
          state.header_bytes +
            Enum.reduce(headers, 0, fn {key, value}, bytes ->
              bytes + byte_size(key) + byte_size(value)
            end)

        if bytes > 64 * 1024 || length(state.headers) + length(headers) > 1_000 do
          {:halt, {:error, :header_limit}}
        else
          {:cont, {:ok, %{state | headers: state.headers ++ headers, header_bytes: bytes}}}
        end

      {:data, ^ref, chunk}, {:ok, state} ->
        bytes = state.bytes + byte_size(chunk)

        if bytes > max_bytes,
          do: {:halt, {:error, :response_limit}},
          else: {:cont, {:ok, %{state | chunks: [chunk | state.chunks], bytes: bytes}}}

      {:done, ^ref}, {:ok, state} ->
        {:cont, {:ok, %{state | done: true}}}

      _, _ ->
        {:halt, {:error, :transport_failure}}
    end)
  end
end
