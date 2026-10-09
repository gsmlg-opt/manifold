defmodule Manifold.Connectors.GmailSyncLimiter do
  @moduledoc """
  Local receive-sync request admission and cooldowns keyed by authorization UUID.

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

  def run(context, callback) when is_function(callback, 0) do
    case GenServer.call(context.server, {:acquire, context.key}) do
      {:ok, claim} ->
        execute(context, claim, callback)

      {:wait, milliseconds} ->
        context.wait.(milliseconds)
        run(context, callback)

      {:error, %Error{}} = error ->
        error
    end
  end

  def success(context) do
    GenServer.call(context.server, {:success, context.key, context.generation})
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:manifold_connectors, :gmail_sync, [])

    {:ok,
     %{
       interval_ms: Keyword.get(opts, :interval_ms, Keyword.get(config, :interval_ms, 500)),
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
        {:reply, {:error, cooldown_error(current.cooldown_until - now)}, state}

      current.claim != nil ->
        {:reply, {:wait, min(state.interval_ms, 500)}, state}

      current.next_allowed != nil and current.next_allowed > now ->
        {:reply, {:wait, min(current.next_allowed - now, 500)}, state}

      true ->
        claim = Process.monitor(caller)
        state = put_entry(state, key, %{current | claim: claim})
        {:reply, {:ok, claim}, %{state | claims: Map.put(state.claims, claim, key)}}
    end
  end

  def handle_call({:finish, claim, error}, _from, state) do
    key = Map.fetch!(state.claims, claim)
    current = entry(state, key)
    now = state.clock.()

    {reply, current} =
      case error do
        %Error{code: :rate_limited} ->
          fallback_ms = Enum.at([30, 60, 120, 240, 300], min(current.errors, 4)) * 1_000
          delay_ms = max(server_delay_ms(error), fallback_ms + state.jitter.())
          deadline = max(current.cooldown_until || now, now + delay_ms)

          updated = %{
            current
            | errors: current.errors + 1,
              generation: current.generation + 1,
              cooldown_until: deadline
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
          {:error, %Error{code: :rate_limited} = error} -> error
          _ -> nil
        end

      case GenServer.call(context.server, {:finish, claim, error}) do
        nil -> result
        %Error{} = error -> {:error, error}
      end
    after
      GenServer.call(context.server, {:release, claim})
    end
  end

  defp release(state, claim, now) do
    case Map.pop(state.claims, claim) do
      {nil, _} ->
        state

      {key, claims} ->
        Process.demonitor(claim, [:flush])
        current = entry(state, key)

        next_allowed = max(current.next_allowed || now, now + state.interval_ms)
        state = put_entry(state, key, %{current | claim: nil, next_allowed: next_allowed})
        %{state | claims: claims}
    end
  end

  defp entry(state, key) do
    Map.get(state.entries, key, %{
      claim: nil,
      next_allowed: nil,
      cooldown_until: nil,
      generation: 0,
      errors: 0
    })
  end

  defp put_entry(state, key, value), do: %{state | entries: Map.put(state.entries, key, value)}

  defp server_delay_ms(%Error{retry_after_seconds: seconds})
       when is_number(seconds) and seconds > 0,
       do: ceil(seconds * 1_000)

  defp server_delay_ms(_error), do: 0
  defp retry_seconds(milliseconds), do: ceil(milliseconds / 1_000)

  defp cooldown_error(milliseconds) do
    %Error{
      class: :temporary,
      code: :rate_limited,
      message: "Gmail receive synchronization is temporarily rate limited",
      retry_after_seconds: retry_seconds(milliseconds)
    }
  end
end
