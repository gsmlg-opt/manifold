defmodule Manifold.SMTP.Admission do
  @moduledoc """
  Owns ephemeral per-peer SMTP connection leases and rate counters.
  """

  use GenServer

  alias Manifold.SMTP.RateLimit

  @type server :: GenServer.server()

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec acquire_connection(String.t(), pid(), server()) ::
          :ok | {:error, :connection_limit | :connection_rate}
  def acquire_connection(peer_ip, owner \\ self(), server \\ __MODULE__) do
    GenServer.call(server, {:acquire_connection, peer_ip, owner})
  end

  @spec allow_transaction(String.t(), server()) :: :ok | {:error, :transaction_rate}
  def allow_transaction(peer_ip, server \\ __MODULE__) do
    GenServer.call(server, {:allow_transaction, peer_ip})
  end

  @spec release_connection(pid(), server()) :: :ok
  def release_connection(owner \\ self(), server \\ __MODULE__) do
    GenServer.call(server, {:release_connection, owner})
  end

  @impl true
  def init(opts) do
    state = %{
      active_by_peer: %{},
      leases: %{},
      connection_windows: %{},
      transaction_windows: %{},
      max_connections_per_peer: Keyword.fetch!(opts, :max_connections_per_peer),
      connection_rate_limit: Keyword.fetch!(opts, :connection_rate_limit),
      connection_rate_window_ms: Keyword.fetch!(opts, :connection_rate_window_ms),
      transaction_rate_limit: Keyword.fetch!(opts, :transaction_rate_limit),
      transaction_rate_window_ms: Keyword.fetch!(opts, :transaction_rate_window_ms),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    }

    prune_interval_ms =
      min(state.connection_rate_window_ms, state.transaction_rate_window_ms)

    Process.send_after(self(), :prune, prune_interval_ms)
    {:ok, Map.put(state, :prune_interval_ms, prune_interval_ms)}
  end

  @impl true
  def handle_call({:acquire_connection, peer_ip, owner}, _from, state) do
    cond do
      Map.has_key?(state.leases, owner) ->
        {:reply, :ok, state}

      Map.get(state.active_by_peer, peer_ip, 0) >= state.max_connections_per_peer ->
        emit(:connection, peer_ip, :rejected, :connection_limit, state)
        {:reply, {:error, :connection_limit}, state}

      true ->
        now_ms = state.clock.()
        window = Map.get(state.connection_windows, peer_ip)

        case RateLimit.check(
               window,
               state.connection_rate_limit,
               state.connection_rate_window_ms,
               now_ms
             ) do
          {:ok, updated_window} ->
            monitor = Process.monitor(owner)

            updated =
              state
              |> put_in([:connection_windows, peer_ip], updated_window)
              |> put_in([:leases, owner], {peer_ip, monitor})
              |> update_in([:active_by_peer, peer_ip], &((&1 || 0) + 1))

            emit(:connection, peer_ip, :accepted, nil, updated)
            {:reply, :ok, updated}

          {:error, retry_after_ms, updated_window} ->
            updated = put_in(state, [:connection_windows, peer_ip], updated_window)
            emit(:connection, peer_ip, :rejected, :connection_rate, updated, retry_after_ms)
            {:reply, {:error, :connection_rate}, updated}
        end
    end
  end

  def handle_call({:allow_transaction, peer_ip}, _from, state) do
    now_ms = state.clock.()
    window = Map.get(state.transaction_windows, peer_ip)

    case RateLimit.check(
           window,
           state.transaction_rate_limit,
           state.transaction_rate_window_ms,
           now_ms
         ) do
      {:ok, updated_window} ->
        updated = put_in(state, [:transaction_windows, peer_ip], updated_window)
        emit(:transaction, peer_ip, :accepted, nil, updated)
        {:reply, :ok, updated}

      {:error, retry_after_ms, updated_window} ->
        updated = put_in(state, [:transaction_windows, peer_ip], updated_window)
        emit(:transaction, peer_ip, :rejected, :transaction_rate, updated, retry_after_ms)
        {:reply, {:error, :transaction_rate}, updated}
    end
  end

  def handle_call({:release_connection, owner}, _from, state) do
    {:reply, :ok, release_lease(state, owner, true)}
  end

  @impl true
  def handle_info({:DOWN, _monitor, :process, owner, _reason}, state) do
    {:noreply, release_lease(state, owner, false)}
  end

  def handle_info(:prune, state) do
    now_ms = state.clock.()

    connection_windows =
      reject_expired(
        state.connection_windows,
        state.connection_rate_window_ms,
        now_ms
      )

    transaction_windows =
      reject_expired(
        state.transaction_windows,
        state.transaction_rate_window_ms,
        now_ms
      )

    Process.send_after(self(), :prune, state.prune_interval_ms)

    {:noreply,
     %{
       state
       | connection_windows: connection_windows,
         transaction_windows: transaction_windows
     }}
  end

  defp release_lease(state, owner, demonitor?) do
    case Map.pop(state.leases, owner) do
      {nil, _leases} ->
        state

      {{peer_ip, monitor}, leases} ->
        if demonitor?, do: Process.demonitor(monitor, [:flush])
        active = max(Map.get(state.active_by_peer, peer_ip, 1) - 1, 0)

        active_by_peer =
          if active == 0 do
            Map.delete(state.active_by_peer, peer_ip)
          else
            Map.put(state.active_by_peer, peer_ip, active)
          end

        updated = %{state | leases: leases, active_by_peer: active_by_peer}
        emit(:connection, peer_ip, :released, nil, updated)
        updated
    end
  end

  defp reject_expired(windows, window_ms, now_ms) do
    Map.reject(windows, fn {_peer_ip, window} ->
      RateLimit.expired?(window, window_ms, now_ms)
    end)
  end

  defp emit(kind, peer_ip, result, reason, state, retry_after_ms \\ nil) do
    :telemetry.execute(
      [:manifold, :smtp, :admission, kind],
      %{
        active_connections: Map.get(state.active_by_peer, peer_ip, 0),
        retry_after_ms: retry_after_ms || 0
      },
      %{peer_ip: peer_ip, result: result, reason: reason}
    )
  end
end
