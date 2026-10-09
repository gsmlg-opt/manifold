defmodule Manifold.Connectors.MicrosoftSyncLimiter do
  @moduledoc """
  Local Graph admission and shared cooldowns keyed by stable mailbox scope.

  Requests and short pacing waits execute in the caller. Long cooldowns return a
  provider error so the sync job can schedule a durable retry.
  """

  use GenServer

  alias Manifold.Connectors.Provider.Error

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def context(key, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    %{
      key: key,
      server: server,
      wait: Keyword.get(opts, :wait, &Process.sleep/1),
      generation: GenServer.call(server, {:generation, key})
    }
  end

  def run(context, callback, opts \\ []) when is_function(callback, 0) do
    case GenServer.call(context.server, {:acquire, context.key}) do
      {:ok, claim} ->
        execute(context, claim, callback)

      {:wait, milliseconds} ->
        context.wait.(milliseconds)
        run(context, callback, opts)

      {:error, %Error{} = error} ->
        on_cooldown = Keyword.get(opts, :on_cooldown, fn error -> {:error, error} end)
        on_cooldown.(error)
    end
  end

  def success(context) do
    GenServer.call(context.server, {:success, context.key, context.generation})
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:manifold_connectors, :microsoft_sync, [])

    {:ok,
     %{
       interval_ms: Keyword.get(opts, :interval_ms, Keyword.get(config, :interval_ms, 500)),
       max_concurrency:
         Keyword.get(opts, :max_concurrency, Keyword.get(config, :max_concurrency, 2)),
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       jitter: Keyword.get(opts, :jitter, fn -> :rand.uniform(1_001) - 1 end),
       entries: %{},
       claims: %{}
     }}
  end

  @impl true
  def handle_call({:generation, key}, _from, state) do
    {:reply, entry(state, key).generation, state}
  end

  def handle_call({:acquire, key}, {caller, _}, state) do
    current = entry(state, key)
    now = state.clock.()

    cond do
      current.cooldown_until != nil and current.cooldown_until > now ->
        {:reply, {:error, cooldown_error(current.cooldown_until - now, current.error_code)},
         state}

      MapSet.size(current.claims) >= state.max_concurrency ->
        {:reply, {:wait, max(min(state.interval_ms, 500), 1)}, state}

      current.next_allowed != nil and current.next_allowed > now ->
        {:reply, {:wait, min(current.next_allowed - now, 500)}, state}

      true ->
        claim = Process.monitor(caller)

        state =
          put_entry(state, key, %{
            current
            | claims: MapSet.put(current.claims, claim),
              next_allowed: now + state.interval_ms
          })

        {:reply, {:ok, claim}, %{state | claims: Map.put(state.claims, claim, key)}}
    end
  end

  def handle_call({:finish, claim, error}, _from, state) do
    key = Map.fetch!(state.claims, claim)
    current = entry(state, key)
    now = state.clock.()

    {reply, current} =
      case error do
        %Error{} ->
          fallback_ms = Enum.at([30, 60, 120, 240, 480, 900], min(current.errors, 5)) * 1_000

          delay_ms =
            case server_delay_ms(error) do
              0 -> fallback_ms + state.jitter.()
              milliseconds -> milliseconds
            end

          deadline = max(current.cooldown_until || now, now + delay_ms)

          updated = %{
            current
            | errors: current.errors + 1,
              generation: current.generation + 1,
              cooldown_until: deadline,
              error_code: error.code
          }

          {%{error | class: :temporary, retry_after_seconds: retry_seconds(deadline - now)},
           updated}

        nil ->
          {nil, current}
      end

    state = put_entry(state, key, current)
    {:reply, reply, release(state, claim, now)}
  end

  def handle_call({:release, claim}, _from, state) do
    {:reply, :ok, release(state, claim, state.clock.())}
  end

  def handle_call({:success, key, generation}, _from, state) do
    current = entry(state, key)

    state =
      if current.generation == generation do
        put_entry(state, key, %{current | errors: 0})
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, claim, :process, _caller, _reason}, state) do
    {:noreply, release(state, claim, state.clock.())}
  end

  defp execute(context, claim, callback) do
    try do
      result = callback.()

      error =
        case result do
          {:error, %Error{class: :temporary, code: code} = error}
          when code in [:http_429, :http_500, :http_502, :http_503, :http_504, :transport_error] ->
            error

          _ ->
            nil
        end

      case GenServer.call(context.server, {:finish, claim, error}) do
        nil -> result
        %Error{} = error -> {:error, error}
      end
    after
      GenServer.call(context.server, {:release, claim})
    end
  end

  defp release(state, claim, _now) do
    case Map.pop(state.claims, claim) do
      {nil, _} ->
        state

      {key, claims} ->
        Process.demonitor(claim, [:flush])
        current = entry(state, key)

        state = put_entry(state, key, %{current | claims: MapSet.delete(current.claims, claim)})
        %{state | claims: claims}
    end
  end

  defp entry(state, key) do
    Map.get(state.entries, key, %{
      claims: MapSet.new(),
      next_allowed: nil,
      cooldown_until: nil,
      generation: 0,
      errors: 0,
      error_code: :http_429
    })
  end

  defp put_entry(state, key, value), do: %{state | entries: Map.put(state.entries, key, value)}

  defp server_delay_ms(%Error{retry_after_seconds: seconds})
       when is_number(seconds) and seconds > 0,
       do: ceil(seconds * 1_000)

  defp server_delay_ms(_error), do: 0
  defp retry_seconds(milliseconds), do: ceil(milliseconds / 1_000)

  defp cooldown_error(milliseconds, code) do
    %Error{
      class: :temporary,
      code: code,
      message: "Microsoft Graph requests are temporarily paused",
      retry_after_seconds: retry_seconds(milliseconds)
    }
  end
end
