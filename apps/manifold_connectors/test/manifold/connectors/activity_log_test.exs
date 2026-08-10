defmodule Manifold.Connectors.ActivityLogTest do
  use ExUnit.Case, async: false

  alias Manifold.Connectors
  alias Manifold.Connectors.ActivityLog

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    log_dir = Path.join(tmp_dir, "connectors")
    previous_dir = Application.get_env(:manifold_connectors, :activity_log_dir)
    previous_days = Application.get_env(:manifold_connectors, :activity_log_retention_days)

    Application.put_env(:manifold_connectors, :activity_log_dir, log_dir)
    Application.put_env(:manifold_connectors, :activity_log_retention_days, 14)

    on_exit(fn ->
      restore(:activity_log_dir, previous_dir)
      restore(:activity_log_retention_days, previous_days)
    end)

    account_id = Ecto.UUID.generate()
    {:ok, log_dir: log_dir, account_id: account_id}
  end

  test "append writes JSONL under account day path", %{account_id: account_id, log_dir: log_dir} do
    today = Date.utc_today()

    assert :ok =
             ActivityLog.append(account_id, %{
               "event" => ["manifold", "connectors", "imap", "auth", "stop"],
               "timestamp" => "2026-08-06T00:00:00.000000Z",
               "measurements" => %{"duration_ms" => 12},
               "metadata" => %{"account_id" => account_id, "result" => "ok"}
             })

    path = Path.join([log_dir, account_id, Date.to_iso8601(today) <> ".log"])
    assert File.exists?(path)
    [line] = path |> File.read!() |> String.split("\n", trim: true)
    assert Jason.decode!(line)["metadata"]["account_id"] == account_id
  end

  test "list_dates returns newest first and rejects traversal", %{account_id: account_id} do
    older = ~D[2026-08-01]
    newer = ~D[2026-08-05]

    assert :ok =
             ActivityLog.append_for_date(account_id, older, %{
               "event" => ["a"],
               "timestamp" => "t",
               "measurements" => %{},
               "metadata" => %{}
             })

    assert :ok =
             ActivityLog.append_for_date(account_id, newer, %{
               "event" => ["b"],
               "timestamp" => "t",
               "measurements" => %{},
               "metadata" => %{}
             })

    assert {:ok, [^newer, ^older]} = ActivityLog.list_dates(account_id)
    assert {:ok, [^newer, ^older]} = Connectors.list_activity_dates(account_id)

    assert {:error, :invalid_account_id} = ActivityLog.list_dates("../etc")
    assert {:error, :invalid_account_id} = ActivityLog.list_dates(account_id <> "/../x")
    assert {:error, :invalid_account_id} = Connectors.list_activity_dates("not-a-uuid")
  end

  test "read returns newest-first last limit lines and skips bad JSON", %{account_id: account_id} do
    today = Date.utc_today()

    assert :ok =
             ActivityLog.append_for_date(account_id, today, %{
               "event" => ["one"],
               "timestamp" => "2026-08-06T00:00:01Z",
               "measurements" => %{},
               "metadata" => %{}
             })

    path = ActivityLog.day_path!(account_id, today)
    File.write!(path, File.read!(path) <> "not-json\n")

    assert :ok =
             ActivityLog.append_for_date(account_id, today, %{
               "event" => ["two"],
               "timestamp" => "2026-08-06T00:00:02Z",
               "measurements" => %{},
               "metadata" => %{}
             })

    assert {:ok, entries} = ActivityLog.read(account_id, today, 200)
    assert Enum.map(entries, & &1["event"]) == [["two"], ["one"]]
    assert {:ok, []} = ActivityLog.read(account_id, ~D[2099-01-01], 200)
    assert {:ok, entries2} = Connectors.read_activity(account_id, today)
    assert length(entries2) == 2
  end

  test "prune deletes files older than retention days", %{account_id: account_id} do
    keep = Date.utc_today()
    drop = Date.add(keep, -20)

    assert :ok = ActivityLog.append_for_date(account_id, keep, sample_entry())
    assert :ok = ActivityLog.append_for_date(account_id, drop, sample_entry())
    assert :ok = ActivityLog.prune(account_id)

    assert {:ok, [^keep]} = ActivityLog.list_dates(account_id)
  end

  test "delete_account removes only the validated account directory and is idempotent", %{
    account_id: account_id,
    log_dir: log_dir
  } do
    other_account_id = Ecto.UUID.generate()
    assert :ok = ActivityLog.append(account_id, sample_entry())
    assert :ok = ActivityLog.append(other_account_id, sample_entry())

    assert :ok = ActivityLog.delete_account(account_id)
    refute File.exists?(Path.join(log_dir, account_id))
    assert File.exists?(Path.join(log_dir, other_account_id))
    assert :ok = ActivityLog.delete_account(account_id)

    for invalid <- ["../etc", account_id <> "/../x", account_id <> "\\x", "not-a-uuid"] do
      assert {:error, :invalid_account_id} = ActivityLog.delete_account(invalid)
    end

    assert File.exists?(Path.join(log_dir, other_account_id))
  end

  defp sample_entry do
    %{
      "event" => ["manifold", "connectors", "sync", "stop"],
      "timestamp" => "2026-08-06T00:00:00Z",
      "measurements" => %{"duration_ms" => 1},
      "metadata" => %{"result" => "ok"}
    }
  end

  defp restore(_key, nil), do: :ok
  defp restore(key, value), do: Application.put_env(:manifold_connectors, key, value)
end
