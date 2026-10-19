defmodule Manifold.CalendarsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Manifold.{Calendars, Repo}
  alias Manifold.Data.Schema.{Calendar, CalendarEvent}

  test "concurrent offline saves serialize on the local calendar and reject the stale revision" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    {:ok, calendar} = Calendars.create_calendar(%{name: "Calendar revision race"})

    {:ok, event} =
      Calendars.create_event(calendar.id, %{starts_at: "20261019", summary: "Original"})

    parent = self()

    tasks =
      for summary <- ["First", "Second"] do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            send(parent, {:ready, self()})

            receive do
              :save -> Calendars.update_event(event.id, %{summary: summary}, expected_revision: 1)
            after
              5_000 -> raise "missing explicit save barrier"
            end
          after
            Sandbox.checkin(Repo)
          end
        end)
      end

    on_exit(fn ->
      Enum.each(tasks, fn task ->
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end)

      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        Repo.delete_all(from e in CalendarEvent, where: e.calendar_id == ^calendar.id)
        Repo.delete_all(from c in Calendar, where: c.id == ^calendar.id)
      after
        Sandbox.checkin(Repo)
      end
    end)

    for task <- tasks do
      expected = task.pid
      assert_receive {:ready, ^expected}, 5_000
    end

    Enum.each(tasks, &send(&1.pid, :save))
    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale})) == 1
    assert Calendars.get_event(event.id).local_revision == 2
    assert Calendars.get_event(event.id).summary in ["First", "Second"]
    Sandbox.checkin(Repo)
  end
end
