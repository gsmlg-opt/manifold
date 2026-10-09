defmodule Manifold.Connectors.GmailSyncLimiterTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.GmailSyncLimiter
  alias Manifold.Connectors.Provider.Error

  @key "00000000-0000-0000-0000-000000000001"
  @other_key "00000000-0000-0000-0000-000000000002"

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})

    server =
      start_supervised!(
        {GmailSyncLimiter,
         name: nil, interval_ms: 500, clock: fn -> now(clock) end, jitter: fn -> 0 end}
      )

    context =
      GmailSyncLimiter.context(@key,
        server: server,
        wait: fn milliseconds -> advance(clock, milliseconds) end
      )

    %{clock: clock, server: server, context: context}
  end

  test "spaces actual dispatch across successive pages", %{clock: clock, context: context} do
    for expected <- [0, 500, 1_000, 1_500] do
      assert {:ok, ^expected} = GmailSyncLimiter.run(context, fn -> {:ok, now(clock)} end)
    end
  end

  test "waits a full interval after the previous request finishes", %{
    clock: clock,
    context: context
  } do
    assert :ok = GmailSyncLimiter.run(context, fn -> advance(clock, 700) end)
    assert {:ok, 1_200} = GmailSyncLimiter.run(context, fn -> {:ok, now(clock)} end)
  end

  test "different authorization keys remain independent", %{
    clock: clock,
    server: server,
    context: context
  } do
    other = GmailSyncLimiter.context(@other_key, server: server, wait: context.wait)
    assert :ok = GmailSyncLimiter.run(context, fn -> :ok end)
    assert {:ok, 0} = GmailSyncLimiter.run(other, fn -> {:ok, now(clock)} end)
    assert {:ok, 500} = GmailSyncLimiter.run(context, fn -> {:ok, now(clock)} end)
  end

  test "only one request per authorization can be in flight", %{
    clock: clock,
    server: server,
    context: context
  } do
    parent = self()

    first =
      Task.async(fn ->
        GmailSyncLimiter.run(context, fn ->
          send(parent, {:entered, self()})
          receive do: (:finish -> :ok)
        end)
      end)

    assert_receive {:entered, first_pid}
    waiting = controlled_context(server, parent)
    second = Task.async(fn -> GmailSyncLimiter.run(waiting, fn -> {:ok, now(clock)} end) end)
    assert_receive {:waiting, second_pid, _}
    other = GmailSyncLimiter.context(@other_key, server: server, wait: context.wait)
    assert :ok = GmailSyncLimiter.run(other, fn -> :ok end)
    advance(clock, 1_000)
    send(second_pid, :wake)
    assert_receive {:waiting, ^second_pid, _}
    send(first_pid, :finish)
    assert :ok = Task.await(first)
    advance(clock, 500)
    send(second_pid, :wake)
    assert {:ok, 1_500} = Task.await(second)
  end

  test "late simultaneous wakeups recheck admission and cannot burst", %{
    clock: clock,
    server: server,
    context: context
  } do
    assert :ok = GmailSyncLimiter.run(context, fn -> :ok end)
    parent = self()
    waiting = controlled_context(server, parent)

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          GmailSyncLimiter.run(waiting, fn ->
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
        GmailSyncLimiter.run(context, fn ->
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
    assert {:ok, 500} = GmailSyncLimiter.run(context, fn -> {:ok, now(clock)} end)
  end

  test "callback exceptions release the claim", %{context: context} do
    assert_raise RuntimeError, "request failed", fn ->
      GmailSyncLimiter.run(context, fn -> raise "request failed" end)
    end

    assert :ok = GmailSyncLimiter.run(context, fn -> :ok end)
  end

  test "active cooldown returns remaining delay without waiting or calling HTTP", %{
    clock: clock,
    server: server,
    context: context
  } do
    assert {:error, %Error{retry_after_seconds: 30}} =
             GmailSyncLimiter.run(context, fn -> rate_limited() end)

    advance(clock, 1_100)
    no_wait = GmailSyncLimiter.context(@key, server: server, wait: fn _ -> flunk("slept") end)

    assert {:error, %Error{class: :temporary, code: :rate_limited, retry_after_seconds: 29}} =
             GmailSyncLimiter.run(no_wait, fn -> flunk("called HTTP") end)

    advance(clock, 28_900)

    assert {:error, %Error{retry_after_seconds: 60}} =
             GmailSyncLimiter.run(no_wait, fn -> rate_limited() end)
  end

  test "a new cooldown interrupts an already waiting caller", %{
    clock: clock,
    server: server,
    context: context
  } do
    assert :ok = GmailSyncLimiter.run(context, fn -> :ok end)
    parent = self()
    waiting = controlled_context(server, parent)
    task = Task.async(fn -> GmailSyncLimiter.run(waiting, fn -> flunk("called HTTP") end) end)
    assert_receive {:waiting, waiter, 500}
    advance(clock, 500)

    assert {:error, %Error{retry_after_seconds: 30}} =
             GmailSyncLimiter.run(context, fn -> rate_limited() end)

    send(waiter, :wake)
    assert {:error, %Error{retry_after_seconds: 30}} = Task.await(task)
  end

  test "repeated limits back off exponentially and cap the fallback", %{
    clock: clock,
    context: context
  } do
    for seconds <- [30, 60, 120, 240, 300, 300] do
      assert {:error, %Error{retry_after_seconds: ^seconds}} =
               GmailSyncLimiter.run(context, fn -> rate_limited() end)

      advance(clock, seconds * 1_000)
    end
  end

  test "server delay is a lower bound and invalid values use fallback", %{
    clock: clock,
    context: context
  } do
    assert {:error, %Error{retry_after_seconds: 3_600}} =
             GmailSyncLimiter.run(context, fn -> rate_limited(3_600) end)

    advance(clock, 3_600_000)

    assert {:error, %Error{retry_after_seconds: 60}} =
             GmailSyncLimiter.run(context, fn -> rate_limited(-1) end)

    advance(clock, 60_000)

    assert {:error, %Error{retry_after_seconds: 120}} =
             GmailSyncLimiter.run(context, fn -> rate_limited("3600") end)
  end

  test "jitter is fresh and milliseconds round up to durable retry seconds", %{clock: clock} do
    parent = self()

    server =
      start_supervised!(
        {GmailSyncLimiter,
         name: nil,
         clock: fn -> now(clock) end,
         jitter: fn ->
           send(parent, :jitter)
           1
         end},
        id: :jitter_limiter
      )

    context = GmailSyncLimiter.context(@key, server: server)

    assert {:error, %Error{retry_after_seconds: 31}} =
             GmailSyncLimiter.run(context, fn -> rate_limited() end)

    assert_receive :jitter
    advance(clock, 30_001)

    assert {:error, %Error{retry_after_seconds: 61}} =
             GmailSyncLimiter.run(context, fn -> rate_limited() end)

    assert_receive :jitter
  end

  test "current successful page resets consecutive limits", %{
    clock: clock,
    server: server,
    context: context
  } do
    assert {:error, %Error{retry_after_seconds: 30}} =
             GmailSyncLimiter.run(context, fn -> rate_limited() end)

    advance(clock, 30_000)
    current = GmailSyncLimiter.context(@key, server: server, wait: context.wait)
    assert :ok = GmailSyncLimiter.run(current, fn -> :ok end)
    assert :ok = GmailSyncLimiter.success(current)

    assert {:error, %Error{retry_after_seconds: 30}} =
             GmailSyncLimiter.run(current, fn -> rate_limited() end)
  end

  test "stale page success never erases a newer cooldown or error count", %{
    clock: clock,
    server: server,
    context: context
  } do
    assert {:error, %Error{retry_after_seconds: 30}} =
             GmailSyncLimiter.run(context, fn -> rate_limited() end)

    current = GmailSyncLimiter.context(@key, server: server, wait: context.wait)
    assert current.generation == context.generation + 1
    assert :ok = GmailSyncLimiter.success(context)

    assert {:error, %Error{retry_after_seconds: 30}} =
             GmailSyncLimiter.run(context, fn -> flunk("called HTTP") end)

    advance(clock, 30_000)

    assert {:error, %Error{retry_after_seconds: 60}} =
             GmailSyncLimiter.run(current, fn -> rate_limited() end)
  end

  defp controlled_context(server, parent) do
    GmailSyncLimiter.context(@key,
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
       code: :rate_limited,
       message: "Gmail temporarily limited receive requests",
       retry_after_seconds: retry_after_seconds
     }}
  end
end
