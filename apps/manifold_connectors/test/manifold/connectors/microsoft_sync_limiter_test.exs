defmodule Manifold.Connectors.MicrosoftSyncLimiterTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.MicrosoftSyncLimiter
  alias Manifold.Connectors.Provider.Error

  @key "00000000-0000-0000-0000-000000000001"
  @other_key "00000000-0000-0000-0000-000000000002"

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})

    server =
      start_supervised!(
        {MicrosoftSyncLimiter,
         name: nil, interval_ms: 500, clock: fn -> now(clock) end, jitter: fn -> 0 end}
      )

    context =
      MicrosoftSyncLimiter.context(@key,
        server: server,
        wait: fn milliseconds -> advance(clock, milliseconds) end
      )

    %{clock: clock, server: server, context: context}
  end

  test "spaces actual dispatch across successive pages", %{clock: clock, context: context} do
    for expected <- [0, 500, 1_000, 1_500] do
      assert {:ok, ^expected} = MicrosoftSyncLimiter.run(context, fn -> {:ok, now(clock)} end)
    end
  end

  test "different authorization keys remain independent", %{
    clock: clock,
    server: server,
    context: context
  } do
    other = MicrosoftSyncLimiter.context(@other_key, server: server, wait: context.wait)
    assert :ok = MicrosoftSyncLimiter.run(context, fn -> :ok end)
    assert {:ok, 0} = MicrosoftSyncLimiter.run(other, fn -> {:ok, now(clock)} end)
    assert {:ok, 500} = MicrosoftSyncLimiter.run(context, fn -> {:ok, now(clock)} end)
  end

  test "two requests can overlap but a third waits without blocking another mailbox", %{
    clock: clock,
    server: server,
    context: context
  } do
    parent = self()

    start = fn ->
      Task.async(fn ->
        MicrosoftSyncLimiter.run(context, fn ->
          send(parent, {:entered, self()})
          receive do: (:finish -> :ok)
        end)
      end)
    end

    first = start.()
    assert_receive {:entered, first_pid}
    advance(clock, 500)
    second = start.()
    assert_receive {:entered, second_pid}
    advance(clock, 500)
    waiting = controlled_context(server, parent)
    third = Task.async(fn -> MicrosoftSyncLimiter.run(waiting, fn -> :ok end) end)
    assert_receive {:waiting, third_pid, _}
    other = MicrosoftSyncLimiter.context(@other_key, server: server, wait: context.wait)
    assert :ok = MicrosoftSyncLimiter.run(other, fn -> :ok end)
    send(first_pid, :finish)
    assert :ok = Task.await(first)
    send(third_pid, :wake)
    assert :ok = Task.await(third)
    send(second_pid, :finish)
    assert :ok = Task.await(second)
  end

  test "late simultaneous wakeups recheck admission and cannot burst", %{
    clock: clock,
    server: server,
    context: context
  } do
    assert :ok = MicrosoftSyncLimiter.run(context, fn -> :ok end)
    parent = self()
    waiting = controlled_context(server, parent)

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          MicrosoftSyncLimiter.run(waiting, fn ->
            send(parent, {:dispatch, self(), now(clock)})
            receive do: (:finish -> :ok)
          end)
        end)
      end

    assert_receive {:waiting, a, 500}
    assert_receive {:waiting, b, 500}
    advance(clock, 5_000)
    send(a, :wake)
    send(b, :wake)
    assert_receive {:dispatch, admitted, 5_000}
    assert_receive {:waiting, delayed, _}
    refute admitted == delayed
    send(admitted, :finish)
    completed = Enum.find(tasks, &(&1.pid == admitted))
    assert :ok = Task.await(completed)
    send(delayed, :wake)
    assert_receive {:waiting, ^delayed, 500}
    advance(clock, 500)
    send(delayed, :wake)
    assert_receive {:dispatch, ^delayed, 5_500}
    send(delayed, :finish)
    assert :ok = tasks |> Enum.find(&(&1.pid == delayed)) |> Task.await()
  end

  test "caller exit releases its monitored claim", %{clock: clock, context: context} do
    parent = self()

    owner =
      spawn(fn ->
        MicrosoftSyncLimiter.run(context, fn ->
          send(parent, :entered)
          receive do: (:finish -> :ok)
        end)
      end)

    monitor = Process.monitor(owner)
    assert_receive :entered
    :erlang.trace(context.server, true, [:receive])
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    server = context.server
    assert_receive {:trace, ^server, :receive, {:DOWN, _, :process, ^owner, :killed}}
    :erlang.trace(server, false, [:receive])
    # The receive trace and this call form a barrier after the monitored release.
    :sys.get_state(context.server)
    assert {:ok, 500} = MicrosoftSyncLimiter.run(context, fn -> {:ok, now(clock)} end)
  end

  test "callback exceptions release the claim", %{context: context} do
    assert_raise RuntimeError, "request failed", fn ->
      MicrosoftSyncLimiter.run(context, fn -> raise "request failed" end)
    end

    assert :ok = MicrosoftSyncLimiter.run(context, fn -> :ok end)
  end

  test "active cooldown returns remaining delay without waiting or calling HTTP", %{
    clock: clock,
    server: server,
    context: context
  } do
    assert {:error, %Error{retry_after_seconds: 30}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited() end)

    advance(clock, 1_100)
    no_wait = MicrosoftSyncLimiter.context(@key, server: server, wait: fn _ -> flunk("slept") end)

    assert {:error, %Error{class: :temporary, code: :http_429, retry_after_seconds: 29}} =
             MicrosoftSyncLimiter.run(no_wait, fn -> flunk("called HTTP") end)

    advance(clock, 28_900)

    assert {:error, %Error{retry_after_seconds: 60}} =
             MicrosoftSyncLimiter.run(no_wait, fn -> rate_limited() end)
  end

  test "a new cooldown interrupts an already waiting caller", %{
    clock: clock,
    server: server,
    context: context
  } do
    assert :ok = MicrosoftSyncLimiter.run(context, fn -> :ok end)
    parent = self()
    waiting = controlled_context(server, parent)
    task = Task.async(fn -> MicrosoftSyncLimiter.run(waiting, fn -> flunk("called HTTP") end) end)
    assert_receive {:waiting, waiter, 500}
    advance(clock, 500)

    assert {:error, %Error{retry_after_seconds: 30}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited() end)

    send(waiter, :wake)
    assert {:error, %Error{retry_after_seconds: 30}} = Task.await(task)
  end

  test "repeated limits back off exponentially and cap the fallback", %{
    clock: clock,
    context: context
  } do
    for seconds <- [30, 60, 120, 240, 480, 900, 900] do
      assert {:error, %Error{retry_after_seconds: ^seconds}} =
               MicrosoftSyncLimiter.run(context, fn -> rate_limited() end)

      advance(clock, seconds * 1_000)
    end
  end

  test "server delay is a lower bound and invalid values use fallback", %{
    clock: clock,
    context: context
  } do
    assert {:error, %Error{retry_after_seconds: 3_600}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited(3_600) end)

    advance(clock, 3_600_000)

    assert {:error, %Error{retry_after_seconds: 60}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited(-1) end)

    advance(clock, 60_000)

    assert {:error, %Error{retry_after_seconds: 120}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited("3600") end)
  end

  test "positive server Retry-After takes precedence over the local fallback", %{context: context} do
    assert {:error, %Error{retry_after_seconds: 5}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited(5) end)
  end

  test "temporary service and transport errors share a safe identifiable cooldown", %{
    clock: clock,
    context: context
  } do
    for {code, seconds} <- [{:http_503, 30}, {:transport_error, 60}] do
      assert {:error, %Error{code: ^code, retry_after_seconds: ^seconds}} =
               MicrosoftSyncLimiter.run(context, fn ->
                 {:error,
                  %Error{class: :temporary, code: code, message: "Temporary provider failure"}}
               end)

      assert {:error, %Error{code: ^code, retry_after_seconds: ^seconds}} =
               MicrosoftSyncLimiter.run(context, fn ->
                 flunk("called HTTP during shared cooldown")
               end)

      advance(clock, seconds * 1_000)
    end
  end

  test "permanent provider failures do not throttle later requests", %{context: context} do
    assert {:error, %Error{class: :permanent}} =
             MicrosoftSyncLimiter.run(context, fn ->
               {:error,
                %Error{class: :permanent, code: :not_found, message: "Missing remote item"}}
             end)

    assert :ok = MicrosoftSyncLimiter.run(context, fn -> :ok end)
  end

  test "jitter is fresh and milliseconds round up to durable retry seconds", %{clock: clock} do
    parent = self()

    server =
      start_supervised!(
        {MicrosoftSyncLimiter,
         name: nil,
         clock: fn -> now(clock) end,
         jitter: fn ->
           send(parent, :jitter)
           1
         end},
        id: :jitter_limiter
      )

    context = MicrosoftSyncLimiter.context(@key, server: server)

    assert {:error, %Error{retry_after_seconds: 31}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited() end)

    assert_receive :jitter
    advance(clock, 30_001)

    assert {:error, %Error{retry_after_seconds: 61}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited() end)

    assert_receive :jitter
  end

  test "current successful page resets consecutive limits", %{
    clock: clock,
    server: server,
    context: context
  } do
    assert {:error, %Error{retry_after_seconds: 30}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited() end)

    advance(clock, 30_000)
    current = MicrosoftSyncLimiter.context(@key, server: server, wait: context.wait)
    assert :ok = MicrosoftSyncLimiter.run(current, fn -> :ok end)
    assert :ok = MicrosoftSyncLimiter.success(current)

    assert {:error, %Error{retry_after_seconds: 30}} =
             MicrosoftSyncLimiter.run(current, fn -> rate_limited() end)
  end

  test "stale page success never erases a newer cooldown or error count", %{
    clock: clock,
    server: server,
    context: context
  } do
    assert {:error, %Error{retry_after_seconds: 30}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited() end)

    current = MicrosoftSyncLimiter.context(@key, server: server, wait: context.wait)
    assert current.generation == context.generation + 1
    assert :ok = MicrosoftSyncLimiter.success(context)

    assert {:error, %Error{retry_after_seconds: 30}} =
             MicrosoftSyncLimiter.run(context, fn -> flunk("called HTTP") end)

    advance(clock, 30_000)

    assert {:error, %Error{retry_after_seconds: 60}} =
             MicrosoftSyncLimiter.run(current, fn -> rate_limited() end)
  end

  test "custom cooldown handler distinguishes admission deferral without calling the request", %{
    clock: clock,
    context: context
  } do
    parent = self()

    on_cooldown = fn error ->
      send(parent, {:deferred, error})
      {:defer, error.retry_after_seconds}
    end

    assert {:error, %Error{retry_after_seconds: 30}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited() end, on_cooldown: on_cooldown)

    refute_received {:deferred, _}

    assert {:defer, 30} =
             MicrosoftSyncLimiter.run(context, fn -> flunk("called request during cooldown") end,
               on_cooldown: on_cooldown
             )

    assert_receive {:deferred, %Error{code: :http_429, retry_after_seconds: 30}}
    advance(clock, 30_000)

    assert {:error, %Error{retry_after_seconds: 60}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited() end, on_cooldown: on_cooldown)

    refute_received {:deferred, _}
  end

  test "custom admission handler survives pacing waits when another request starts cooldown", %{
    clock: clock,
    server: server,
    context: context
  } do
    assert :ok = MicrosoftSyncLimiter.run(context, fn -> :ok end)
    parent = self()
    waiting = controlled_context(server, parent)

    task =
      Task.async(fn ->
        MicrosoftSyncLimiter.run(waiting, fn -> flunk("called request") end,
          on_cooldown: fn error -> {:defer, error.code, error.retry_after_seconds} end
        )
      end)

    assert_receive {:waiting, waiter, 500}
    advance(clock, 500)

    assert {:error, %Error{retry_after_seconds: 30}} =
             MicrosoftSyncLimiter.run(context, fn -> rate_limited() end)

    send(waiter, :wake)
    assert {:defer, :http_429, 30} = Task.await(task)
  end

  defp controlled_context(server, parent) do
    MicrosoftSyncLimiter.context(@key,
      server: server,
      wait: fn milliseconds ->
        send(parent, {:waiting, self(), milliseconds})
        receive do: (:wake -> :ok)
      end
    )
  end

  defp now(clock), do: Agent.get(clock, & &1)
  defp advance(clock, milliseconds), do: Agent.update(clock, &(&1 + milliseconds))

  defp rate_limited(retry_after_seconds \\ nil) do
    {:error,
     %Error{
       class: :temporary,
       code: :http_429,
       message: "Microsoft temporarily limited receive requests",
       retry_after_seconds: retry_after_seconds
     }}
  end
end
