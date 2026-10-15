defmodule Manifold.Core.HTTPClient.Test do
  @moduledoc "Process-owned HTTP expectations for application tests."
  alias Manifold.Core.HTTPClient.TransportError

  def expect(name, count \\ 1, callback) when is_integer(count) and count > 0 do
    owner = self()

    update(fn state ->
      key = {owner, name}

      Map.update(state, key, %{queue: List.duplicate(callback, count), stub: nil}, fn entry ->
        %{entry | queue: entry.queue ++ List.duplicate(callback, count)}
      end)
    end)

    name
  end

  def stub(name, callback) do
    owner = self()

    update(fn state ->
      Map.update(state, {owner, name}, %{queue: [], stub: callback}, &%{&1 | stub: callback})
    end)

    :ok
  end

  def allow(name, owner, allowed) do
    allowed = if is_function(allowed, 0), do: allowed.(), else: allowed
    update(&Map.put(&1, {:allow, allowed, name}, owner))
    :ok
  end

  def verify_on_exit!(_context \\ %{}) do
    owner = self()

    ExUnit.Callbacks.on_exit({__MODULE__, owner}, fn ->
      try do
        verify(owner, :all)
      after
        update(fn state ->
          Enum.reject(state, fn {key, value} -> owned?(key, value, owner) end) |> Map.new()
        end)
      end
    end)

    :ok
  end

  def verify!, do: verify(self(), :all)
  def verify!(name), do: verify(self(), name)

  defp verify(owner, name) do
    pending =
      query(fn state ->
        for {{^owner, key}, %{queue: [_ | _] = queue}} <- state,
            name in [:all, key],
            do: {key, length(queue)}
      end)

    if pending != [], do: raise("HTTP expectations remain unconsumed: #{inspect(pending)}")
    :ok
  end

  defp owned?({owner, _}, _, owner), do: true
  defp owned?({:allow, _, _}, owner, owner), do: true
  defp owned?(_, _, _), do: false

  def json(conn, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(conn.status || 200, Jason.encode!(data))
  end

  def transport_error(conn, reason),
    do: Plug.Conn.put_private(conn, :http_client_test_exception, %TransportError{reason: reason})

  def request(method, url, headers, body, plug) do
    conn = Plug.Test.conn(method, url, body)
    conn = %{conn | req_headers: headers}
    conn = call_plug(conn, plug)

    case conn.private[:http_client_test_exception] do
      nil ->
        {:ok,
         %{
           status: conn.status || 200,
           headers: conn.resp_headers,
           body: IO.iodata_to_binary(conn.resp_body || "")
         }}

      error ->
        {:error, error}
    end
  end

  def init(name), do: name
  def call(conn, name), do: call_plug(conn, fetch(name))
  defp call_plug(conn, {module, opts}), do: module.call(conn, module.init(opts))
  defp call_plug(conn, function) when is_function(function, 1), do: function.(conn)
  defp call_plug(conn, function) when is_function(function, 2), do: function.(conn, [])
  defp call_plug(conn, module), do: module.call(conn, module.init([]))

  defp fetch(name) do
    callers =
      [self()] ++ List.wrap(Process.get(:"$callers")) ++ List.wrap(Process.get(:"$ancestors"))

    {result, _} =
      mutate(fn state ->
        owner =
          Enum.find_value(callers, fn caller ->
            cond do
              Map.has_key?(state, {caller, name}) ->
                caller

              Map.has_key?(state, {:allow, caller, name}) ->
                Map.fetch!(state, {:allow, caller, name})

              true ->
                nil
            end
          end)

        case Map.get(state, {owner, name}) do
          %{queue: [callback | rest]} = entry ->
            {callback, Map.put(state, {owner, name}, %{entry | queue: rest})}

          %{queue: [], stub: callback} when not is_nil(callback) ->
            {callback, state}

          _ ->
            {:missing, state}
        end
      end)

    if result == :missing, do: raise("no HTTP expectation for #{inspect(name)}"), else: result
  end

  defp ensure_agent do
    case Agent.start(fn -> %{} end, name: __MODULE__.Owners) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp update(fun) do
    ensure_agent()
    Agent.update(__MODULE__.Owners, fun)
  end

  defp query(fun) do
    ensure_agent()
    Agent.get(__MODULE__.Owners, fun)
  end

  defp mutate(fun) do
    ensure_agent()

    Agent.get_and_update(__MODULE__.Owners, fn state ->
      {result, new_state} = fun.(state)
      {{result, new_state}, new_state}
    end)
  end
end
