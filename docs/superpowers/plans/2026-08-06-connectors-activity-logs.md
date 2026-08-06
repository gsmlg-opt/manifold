# Connectors Activity Logs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make IMAP connect/auth/select and Sync failures visible per account via `:telemetry` → append-only JSONL activity files → Settings Activity LiveView.

**Architecture:** Domain code (IMAP Client/Fake, Sync) emits `:stop` span telemetry with `duration_ms` and safe metadata. `Manifold.Connectors.ActivityLog.Handler` attaches at Connectors Application start and appends one JSON line per event under `log/connectors/<account_id>/YYYY-MM-DD.log` when `account_id` is present. `Manifold.Connectors.list_activity_dates/1` and `read_activity/3` read those files for the Settings LiveView at `/settings/accounts/:id/activity`.

**Tech Stack:** Elixir 1.18, `:telemetry`, Jason, Phoenix LiveView, ExUnit, existing IMAP Fake transport.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-06-connectors-activity-logs-design.md`
- Never log password, app password, OAuth token, refresh token, or ciphertext
- Only write activity files when `account_id` is present and a valid UUID path segment
- Pre-create / connection-test failures without `account_id` stay on form `imap_error` + Logger; no activity file
- Retention default: `14` days via `:activity_log_retention_days`
- Default dir: `"log/connectors"` via `:activity_log_dir` under `:manifold_connectors`
- v1 events only: imap connect/auth/select stop + sync stop; no PubSub push; no DB dual-write; no cross-account browser
- Run tests via `devenv shell -- mix test …` unless already inside devenv
- Prefer TDD: failing test → implement → pass → commit per task
- Public module is `Manifold.Connectors` (spec shorthand `Connectors.*`)

---

## File Map

| Path | Responsibility |
| --- | --- |
| Create: `apps/manifold_connectors/lib/manifold/connectors/activity_log.ex` | Path safety, append JSONL, list dates, read last N lines, retention prune |
| Create: `apps/manifold_connectors/lib/manifold/connectors/activity_log/handler.ex` | `:telemetry` handler; filter events; skip missing `account_id`; append + prune |
| Create: `apps/manifold_connectors/test/manifold/connectors/activity_log_test.exs` | Storage / path / read / retention tests |
| Create: `apps/manifold_connectors/test/manifold/connectors/activity_log/handler_test.exs` | Handler write / skip / secret scrub tests |
| Modify: `apps/manifold_connectors/lib/manifold/connectors/application.ex` | Call `Handler.attach/0` on start |
| Modify: `apps/manifold_connectors/lib/manifold/connectors.ex` | Expose `list_activity_dates/1`, `read_activity/3` |
| Modify: `apps/manifold_connectors/lib/manifold/connectors/imap/client.ex` | Emit connect/auth/select `:stop` telemetry |
| Modify: `apps/manifold_connectors/lib/manifold/connectors/imap/fake.ex` | Mirror connect/auth/select telemetry for Fake IMAP |
| Modify: `apps/manifold_connectors/lib/manifold/connectors/provider/imap.ex` | Pass optional `account_id` into transport settings |
| Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex` | Put `account_id` in IMAP runtime config; emit sync `:stop` |
| Create: `apps/manifold_connectors/test/manifold/connectors/activity_log_imap_test.exs` | Fake IMAP integration → JSONL entries |
| Create: `apps/manifold_web/lib/manifold_web/live/external_account_live/activity.ex` | Activity LiveView (date picker, list, refresh) |
| Modify: `apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex` | Per-account Activity link |
| Modify: `apps/manifold_web/lib/manifold_web/router.ex` | Route `/settings/accounts/:id/activity` |
| Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs` | LiveView activity tests |
| Modify: `config/config.exs` | Default `:activity_log_dir`, `:activity_log_retention_days` |
| Modify: `config/test.exs` | Test activity log dir under `tmp/` |

---

### Task 1: ActivityLog storage API and config

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/activity_log.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Test: `apps/manifold_connectors/test/manifold/connectors/activity_log_test.exs`

**Interfaces:**
- Consumes: Application env `:manifold_connectors` keys `:activity_log_dir`, `:activity_log_retention_days`
- Produces:
  - `Manifold.Connectors.ActivityLog.append/2` — `append(account_id, entry_map) :: :ok | {:error, term()}`
  - `Manifold.Connectors.ActivityLog.list_dates/1` — `list_dates(account_id) :: {:ok, [Date.t()]} | {:error, :invalid_account_id}`
  - `Manifold.Connectors.ActivityLog.read/3` — `read(account_id, date, limit \\ 200) :: {:ok, [map()]} | {:error, :invalid_account_id}`
  - `Manifold.Connectors.ActivityLog.prune/1` — `prune(account_id) :: :ok`
  - `Manifold.Connectors.list_activity_dates/1` and `read_activity/3` delegates

- [ ] **Step 1: Write the failing storage tests**

```elixir
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

    assert :ok = ActivityLog.append_for_date(account_id, older, %{"event" => ["a"], "timestamp" => "t", "measurements" => %{}, "metadata" => %{}})
    assert :ok = ActivityLog.append_for_date(account_id, newer, %{"event" => ["b"], "timestamp" => "t", "measurements" => %{}, "metadata" => %{}})

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
    File.write!(path, File.read!(path) <> "not-json\n", [:append])

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
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/activity_log_test.exs
```

Expected: FAIL with module `Manifold.Connectors.ActivityLog` undefined (or similar compile/load error).

- [ ] **Step 3: Add config defaults**

In `config/config.exs`, extend the existing `config :manifold_connectors` block:

```elixir
config :manifold_connectors,
  adapters: [
    gmail: Manifold.Connectors.Provider.Gmail,
    microsoft: Manifold.Connectors.Provider.MicrosoftGraph
  ],
  activity_log_dir: "log/connectors",
  activity_log_retention_days: 14,
  providers: [
    # ... existing providers unchanged ...
  ]
```

In `config/test.exs`, inside the existing `config :manifold_connectors` block add:

```elixir
config :manifold_connectors,
  encryption_key: "A/6Bm4le6HQiXyh+gE1NQr2+RLEcEpZ/JSPBt4y1Lrk=",
  activity_log_dir: Path.expand("../tmp/test_activity_logs", __DIR__),
  activity_log_retention_days: 14,
  providers: [
    # ... existing providers unchanged ...
  ]
```

- [ ] **Step 4: Implement ActivityLog and Connectors delegates**

Create `apps/manifold_connectors/lib/manifold/connectors/activity_log.ex`:

```elixir
defmodule Manifold.Connectors.ActivityLog do
  @moduledoc false

  @uuid_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @spec append(String.t(), map()) :: :ok | {:error, term()}
  def append(account_id, entry) when is_map(entry) do
    append_for_date(account_id, Date.utc_today(), entry)
  end

  @spec append_for_date(String.t(), Date.t(), map()) :: :ok | {:error, term()}
  def append_for_date(account_id, %Date{} = date, entry) when is_map(entry) do
    with {:ok, account_id} <- validate_account_id(account_id),
         dir <- account_dir(account_id),
         :ok <- File.mkdir_p(dir),
         path <- day_path(account_id, date),
         line <- Jason.encode!(entry) <> "\n",
         :ok <- File.write(path, line, [:append]) do
      :ok
    end
  end

  @spec list_dates(String.t()) :: {:ok, [Date.t()]} | {:error, :invalid_account_id}
  def list_dates(account_id) do
    with {:ok, account_id} <- validate_account_id(account_id) do
      dir = account_dir(account_id)

      dates =
        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.ends_with?(&1, ".log"))
            |> Enum.flat_map(fn name ->
              case Date.from_iso8601(String.trim_trailing(name, ".log")) do
                {:ok, date} -> [date]
                _ -> []
              end
            end)
            |> Enum.sort({:desc, Date})

          {:error, :enoent} ->
            []

          {:error, _} ->
            []
        end

      {:ok, dates}
    end
  end

  @spec read(String.t(), Date.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, :invalid_account_id}
  def read(account_id, %Date{} = date, limit \\ 200)
      when is_integer(limit) and limit > 0 do
    with {:ok, account_id} <- validate_account_id(account_id) do
      path = day_path(account_id, date)

      entries =
        case File.read(path) do
          {:ok, contents} ->
            contents
            |> String.split("\n", trim: true)
            |> Enum.reverse()
            |> Enum.reduce_while({[], 0}, fn line, {acc, count} ->
              if count >= limit do
                {:halt, {acc, count}}
              else
                case Jason.decode(line) do
                  {:ok, map} when is_map(map) -> {:cont, {[map | acc], count + 1}}
                  _ -> {:cont, {acc, count}}
                end
              end
            end)
            |> elem(0)
            |> Enum.reverse()

          {:error, :enoent} ->
            []

          {:error, _} ->
            []
        end

      {:ok, entries}
    end
  end

  @spec prune(String.t()) :: :ok | {:error, :invalid_account_id}
  def prune(account_id) do
    with {:ok, account_id} <- validate_account_id(account_id),
         {:ok, dates} <- list_dates(account_id) do
      cutoff = Date.add(Date.utc_today(), -retention_days())

      Enum.each(dates, fn date ->
        if Date.compare(date, cutoff) == :lt do
          _ = File.rm(day_path(account_id, date))
        end
      end)

      :ok
    end
  end

  @doc false
  def day_path!(account_id, date) do
    {:ok, account_id} = validate_account_id(account_id)
    day_path(account_id, date)
  end

  @spec validate_account_id(term()) :: {:ok, String.t()} | {:error, :invalid_account_id}
  def validate_account_id(account_id) when is_binary(account_id) do
    cond do
      String.contains?(account_id, ["..", "/", "\\"]) ->
        {:error, :invalid_account_id}

      Regex.match?(@uuid_re, account_id) ->
        {:ok, account_id}

      true ->
        {:error, :invalid_account_id}
    end
  end

  def validate_account_id(_), do: {:error, :invalid_account_id}

  defp day_path(account_id, %Date{} = date),
    do: Path.join(account_dir(account_id), Date.to_iso8601(date) <> ".log")

  defp account_dir(account_id), do: Path.join(root_dir(), account_id)

  defp root_dir do
    Application.get_env(:manifold_connectors, :activity_log_dir, "log/connectors")
  end

  defp retention_days do
    Application.get_env(:manifold_connectors, :activity_log_retention_days, 14)
  end
end
```

In `apps/manifold_connectors/lib/manifold/connectors.ex`, add near other public API functions (after `get_account/1`):

```elixir
@spec list_activity_dates(Ecto.UUID.t()) :: {:ok, [Date.t()]} | {:error, :invalid_account_id}
def list_activity_dates(account_id), do: ActivityLog.list_dates(account_id)

@spec read_activity(Ecto.UUID.t(), Date.t(), pos_integer()) ::
        {:ok, [map()]} | {:error, :invalid_account_id}
def read_activity(account_id, date, limit \\ 200),
  do: ActivityLog.read(account_id, date, limit)
```

And add `alias Manifold.Connectors.ActivityLog` with the other aliases.

**Read newest-first note:** Returned list must be newest first (spec). The implementation above reverses file lines, takes up to `limit` valid JSON objects, then reverses the accumulator so the list is newest-first.

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/activity_log_test.exs
```

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add \
  apps/manifold_connectors/lib/manifold/connectors/activity_log.ex \
  apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_connectors/test/manifold/connectors/activity_log_test.exs \
  config/config.exs \
  config/test.exs
git commit -m "$(cat <<'EOF'
feat(connectors): add activity log storage and read API.

EOF
)"
```

---

### Task 2: Telemetry handler attach at Application start

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/activity_log/handler.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/application.ex`
- Test: `apps/manifold_connectors/test/manifold/connectors/activity_log/handler_test.exs`

**Interfaces:**
- Consumes: `ActivityLog.append/2`, `ActivityLog.prune/1`, `ActivityLog.validate_account_id/1`
- Produces:
  - `Manifold.Connectors.ActivityLog.Handler.attach/0` :: `:ok`
  - `Manifold.Connectors.ActivityLog.Handler.detach/0` :: `:ok`
  - `handle_event/4` writing JSONL for v1 event names only
  - Events handled:
    - `[:manifold, :connectors, :imap, :connect, :stop]`
    - `[:manifold, :connectors, :imap, :auth, :stop]`
    - `[:manifold, :connectors, :imap, :select, :stop]`
    - `[:manifold, :connectors, :sync, :stop]`

- [ ] **Step 1: Write failing handler tests**

```elixir
defmodule Manifold.Connectors.ActivityLog.HandlerTest do
  use ExUnit.Case, async: false

  alias Manifold.Connectors.ActivityLog
  alias Manifold.Connectors.ActivityLog.Handler

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    log_dir = Path.join(tmp_dir, "connectors")
    previous_dir = Application.get_env(:manifold_connectors, :activity_log_dir)
    Application.put_env(:manifold_connectors, :activity_log_dir, log_dir)

    Handler.detach()
    assert :ok = Handler.attach()

    on_exit(fn ->
      Handler.detach()
      restore(:activity_log_dir, previous_dir)
    end)

    {:ok, account_id: Ecto.UUID.generate(), log_dir: log_dir}
  end

  test "emit with account_id appends JSONL line", %{account_id: account_id} do
    :telemetry.execute(
      [:manifold, :connectors, :imap, :auth, :stop],
      %{duration_ms: 9},
      %{
        account_id: account_id,
        host: "imap.example",
        port: 993,
        tls_mode: "ssl",
        username: "reader@imap.example",
        provider: "imap",
        result: :ok
      }
    )

    assert {:ok, [entry]} = ActivityLog.read(account_id, Date.utc_today())
    assert entry["event"] == ["manifold", "connectors", "imap", "auth", "stop"]
    assert entry["measurements"]["duration_ms"] == 9
    assert entry["metadata"]["account_id"] == account_id
    assert entry["metadata"]["result"] == "ok"
    refute Map.has_key?(entry["metadata"], "password")
  end

  test "emit without account_id skips write", %{log_dir: log_dir} do
    :telemetry.execute(
      [:manifold, :connectors, :imap, :connect, :stop],
      %{duration_ms: 1},
      %{host: "imap.example", result: :error, error_code: :connect_failed}
    )

    assert File.ls!(log_dir) == []
  end

  test "handler drops secret-looking metadata keys", %{account_id: account_id} do
    :telemetry.execute(
      [:manifold, :connectors, :imap, :auth, :stop],
      %{duration_ms: 2},
      %{
        account_id: account_id,
        username: "reader@imap.example",
        password: "super-secret",
        refresh_token: "tok",
        result: :error,
        error_code: :auth_failed,
        error_message: "IMAP authentication failed"
      }
    )

    assert {:ok, [entry]} = ActivityLog.read(account_id, Date.utc_today())
    meta = entry["metadata"]
    refute Map.has_key?(meta, "password")
    refute Map.has_key?(meta, "refresh_token")
    assert meta["username"] == "reader@imap.example"
    assert meta["error_code"] == "auth_failed"
  end

  defp restore(_key, nil), do: :ok
  defp restore(key, value), do: Application.put_env(:manifold_connectors, key, value)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/activity_log/handler_test.exs
```

Expected: FAIL with `Handler` undefined.

- [ ] **Step 3: Implement Handler and attach from Application**

Create `apps/manifold_connectors/lib/manifold/connectors/activity_log/handler.ex`:

```elixir
defmodule Manifold.Connectors.ActivityLog.Handler do
  @moduledoc false

  alias Manifold.Connectors.ActivityLog

  @handler_id "manifold-connectors-activity-log"
  @events [
    [:manifold, :connectors, :imap, :connect, :stop],
    [:manifold, :connectors, :imap, :auth, :stop],
    [:manifold, :connectors, :imap, :select, :stop],
    [:manifold, :connectors, :sync, :stop]
  ]

  @allowed_metadata [
    :account_id,
    :host,
    :port,
    :tls_mode,
    :username,
    :mailbox_path,
    :uidvalidity,
    :provider,
    :result,
    :error_code,
    :error_message
  ]

  @spec attach() :: :ok
  def attach do
    detach()

    :ok =
      :telemetry.attach_many(
        @handler_id,
        @events,
        &__MODULE__.handle_event/4,
        %{}
      )

    :ok
  end

  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, _config)
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    account_id = metadata[:account_id] || metadata["account_id"]

    with {:ok, account_id} <- ActivityLog.validate_account_id(account_id) do
      entry = %{
        "event" => Enum.map(event, &to_string/1),
        "timestamp" => DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
        "measurements" => normalize_measurements(measurements),
        "metadata" => normalize_metadata(metadata, account_id)
      }

      _ = ActivityLog.append(account_id, entry)
      _ = ActivityLog.prune(account_id)
    end

    :ok
  rescue
    _ -> :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp normalize_measurements(measurements) do
    measurements
    |> Map.take([:duration_ms, :message_count, :page_count, "duration_ms", "message_count", "page_count"])
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_metadata(metadata, account_id) do
    metadata
    |> Map.take(@allowed_metadata ++ Enum.map(@allowed_metadata, &to_string/1))
    |> Map.put(:account_id, account_id)
    |> Map.new(fn {k, v} -> {to_string(k), normalize_value(v)} end)
  end

  defp normalize_value(v) when is_atom(v), do: Atom.to_string(v)
  defp normalize_value(v), do: v
end
```

Replace `apps/manifold_connectors/lib/manifold/connectors/application.ex` with:

```elixir
defmodule Manifold.Connectors.Application do
  @moduledoc false

  use Application

  alias Manifold.Connectors.ActivityLog.Handler

  @impl true
  def start(_type, _args) do
    Handler.attach()

    Supervisor.start_link([], strategy: :one_for_one, name: Manifold.Connectors.Supervisor)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/activity_log/handler_test.exs
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add \
  apps/manifold_connectors/lib/manifold/connectors/activity_log/handler.ex \
  apps/manifold_connectors/lib/manifold/connectors/application.ex \
  apps/manifold_connectors/test/manifold/connectors/activity_log/handler_test.exs
git commit -m "$(cat <<'EOF'
feat(connectors): attach activity log telemetry handler.

EOF
)"
```

---

### Task 3: Emit IMAP connect / auth / select telemetry

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/imap/client.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/imap/fake.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/provider/imap.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex` (only `enrich_runtime_config/2` — add `:account_id`)
- Test: extend `apps/manifold_connectors/test/manifold/connectors/imap/fake_test.exs` or create `apps/manifold_connectors/test/manifold/connectors/imap/telemetry_test.exs`

**Interfaces:**
- Consumes: optional `:account_id` in IMAP settings map / provider config
- Produces telemetry:
  - `[:manifold, :connectors, :imap, :connect, :stop]` measurements `%{duration_ms: integer}`
  - `[:manifold, :connectors, :imap, :auth, :stop]` same
  - `[:manifold, :connectors, :imap, :select, :stop]` same
  - metadata keys from spec when known (`account_id`, `host`, `port`, `tls_mode`, `username` on auth, `mailbox_path` / `uidvalidity` on select, `provider: "imap"`, `result`, `error_code`, `error_message`)
- Never put `password` in metadata

- [ ] **Step 1: Write failing telemetry contract tests**

Create `apps/manifold_connectors/test/manifold/connectors/imap/telemetry_test.exs`:

```elixir
defmodule Manifold.Connectors.IMAP.TelemetryTest do
  use ExUnit.Case, async: false

  alias Manifold.Connectors.IMAP.Fake

  setup do
    handler_id = "imap-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:manifold, :connectors, :imap, :connect, :stop],
          [:manifold, :connectors, :imap, :auth, :stop],
          [:manifold, :connectors, :imap, :select, :stop]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "Fake connect success emits connect and auth stop with duration_ms" do
    account_id = Ecto.UUID.generate()

    assert {:ok, conn} =
             Fake.connect(%{
               host: "imap.example",
               port: 993,
               tls_mode: "ssl",
               username: "user@example",
               password: "secret",
               password_expected: "secret",
               account_id: account_id
             })

    assert_receive {:telemetry, [:manifold, :connectors, :imap, :connect, :stop],
                    %{duration_ms: connect_ms},
                    %{account_id: ^account_id, result: :ok, provider: "imap"}}

    assert is_integer(connect_ms)

    assert_receive {:telemetry, [:manifold, :connectors, :imap, :auth, :stop],
                    %{duration_ms: auth_ms}, meta}

    assert is_integer(auth_ms)
    assert meta.account_id == account_id
    assert meta.result == :ok
    assert meta.username == "user@example"
    assert meta.provider == "imap"
    refute Map.has_key?(meta, :password)

    assert {:ok, %{uidvalidity: 1}} = Fake.select(conn, "INBOX")

    assert_receive {:telemetry, [:manifold, :connectors, :imap, :select, :stop],
                    %{duration_ms: _},
                    %{
                      account_id: ^account_id,
                      result: :ok,
                      mailbox_path: "INBOX",
                      uidvalidity: 1
                    }}

    Fake.logout(conn)
  end

  test "Fake auth failure emits connect ok and auth error" do
    account_id = Ecto.UUID.generate()

    assert {:error, %{code: :auth_failed}} =
             Fake.connect(%{
               host: "imap.example",
               port: 993,
               tls_mode: "ssl",
               username: "user@example",
               password: "wrong",
               password_expected: "secret",
               account_id: account_id
             })

    assert_receive {:telemetry, [:manifold, :connectors, :imap, :connect, :stop], _,
                    %{result: :ok, account_id: ^account_id}}

    assert_receive {:telemetry, [:manifold, :connectors, :imap, :auth, :stop], _,
                    %{
                      result: :error,
                      error_code: :auth_failed,
                      account_id: ^account_id
                    }}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/imap/telemetry_test.exs
```

Expected: FAIL — no telemetry messages received (timeout on `assert_receive`).

- [ ] **Step 3: Pass account_id through provider/sync settings**

In `provider/imap.ex` `settings/2`, add optional account_id:

```elixir
defp settings(password, config) do
  base = %{
    host: Keyword.fetch!(config, :host),
    port: Keyword.fetch!(config, :port),
    tls_mode: Keyword.fetch!(config, :tls_mode),
    username: Keyword.fetch!(config, :username),
    password: password,
    mailbox_path: Keyword.get(config, :mailbox_path, "INBOX")
  }

  base =
    case Keyword.get(config, :account_id) do
      id when is_binary(id) -> Map.put(base, :account_id, id)
      _ -> base
    end

  case Keyword.get(config, :fake) do
    %{} = fake -> Map.merge(base, fake)
    _ -> base
  end
end
```

In `sync.ex` `enrich_runtime_config/2` for IMAP, add `account_id: account.id` to the `Keyword.merge/2` list.

- [ ] **Step 4: Instrument Fake**

Update `Fake.connect/1` and `Fake.select/2` to emit telemetry. Full replacement of those two functions:

```elixir
@impl true
def connect(settings) when is_map(settings) do
  connect_start = System.monotonic_time()
  base_meta = base_meta(settings)

  emit([:manifold, :connectors, :imap, :connect, :stop], connect_start, base_meta, :ok)

  auth_start = System.monotonic_time()
  expected = Map.get(settings, :password_expected)

  if is_binary(expected) and settings.password != expected do
    error = %Error{
      class: :reconnect,
      code: :auth_failed,
      message: "IMAP authentication failed"
    }

    emit([:manifold, :connectors, :imap, :auth, :stop], auth_start, auth_meta(settings), error)
    {:error, error}
  else
    emit([:manifold, :connectors, :imap, :auth, :stop], auth_start, auth_meta(settings), :ok)
    {:ok, pid} = Agent.start_link(fn -> %{settings: settings, selected: nil} end)
    {:ok, pid}
  end
end

@impl true
def select(conn, mailbox_path) when is_pid(conn) and is_binary(mailbox_path) do
  start = System.monotonic_time()
  settings = Agent.get(conn, & &1.settings)
  Agent.update(conn, &%{&1 | selected: mailbox_path})
  uidvalidity = Map.get(settings, :uidvalidity, 1)
  uidnext = Map.get(settings, :uidnext)

  meta =
    settings
    |> base_meta()
    |> Map.merge(%{mailbox_path: mailbox_path, uidvalidity: uidvalidity})

  emit([:manifold, :connectors, :imap, :select, :stop], start, meta, :ok)
  {:ok, %{uidvalidity: uidvalidity, uidnext: uidnext}}
end
```

Add private helpers at the bottom of `Fake`:

```elixir
defp base_meta(settings) do
  %{
    host: Map.get(settings, :host),
    port: Map.get(settings, :port),
    tls_mode: Map.get(settings, :tls_mode),
    provider: "imap"
  }
  |> maybe_put(:account_id, Map.get(settings, :account_id))
end

defp auth_meta(settings) do
  settings
  |> base_meta()
  |> maybe_put(:username, Map.get(settings, :username))
end

defp maybe_put(map, _key, nil), do: map
defp maybe_put(map, key, value), do: Map.put(map, key, value)

defp emit(event, start, meta, :ok) do
  :telemetry.execute(
    event,
    %{duration_ms: now_ms(start)},
    Map.put(meta, :result, :ok)
  )
end

defp emit(event, start, meta, %Error{} = error) do
  :telemetry.execute(
    event,
    %{duration_ms: now_ms(start)},
    meta
    |> Map.put(:result, :error)
    |> Map.put(:error_code, error.code)
    |> Map.put(:error_message, error.message)
  )
end

defp now_ms(start) do
  System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
end
```

- [ ] **Step 5: Instrument Client.connect and Client.select**

Refactor `Client.connect/1` so TCP/greeting and LOGIN are timed separately. Replace the body of `connect/1` with:

```elixir
def connect(settings) when is_map(settings) do
  host = settings |> Map.fetch!(:host) |> normalize_host()
  port = normalize_port(Map.fetch!(settings, :port))
  tls_mode = Map.fetch!(settings, :tls_mode)
  username = settings |> Map.fetch!(:username) |> normalize_text()
  password = Map.fetch!(settings, :password)
  base_meta = imap_base_meta(settings, host, port, tls_mode)

  connect_start = System.monotonic_time()

  with {:ok, host} <- require_host(host),
       {:ok, port} <- require_port(port),
       {:ok, conn} <- open_and_greet_safe(host, port, tls_mode) do
    emit_imap([:manifold, :connectors, :imap, :connect, :stop], connect_start, base_meta, :ok)

    auth_start = System.monotonic_time()
    auth_meta = Map.put(base_meta, :username, username)

    case command(conn, "LOGIN #{quote_string(username)} #{quote_string(password)}", auth: true) do
      {:ok, conn} ->
        emit_imap([:manifold, :connectors, :imap, :auth, :stop], auth_start, auth_meta, :ok)
        put_conn(conn)
        {:ok, conn}

      {:error, %Error{} = error} ->
        emit_imap([:manifold, :connectors, :imap, :auth, :stop], auth_start, auth_meta, error)
        {:error, error}
    end
  else
    {:error, %Error{} = error} ->
      emit_imap([:manifold, :connectors, :imap, :connect, :stop], connect_start, base_meta, error)
      {:error, error}

    {:error, :timeout} ->
      error = %Error{class: :temporary, code: :timeout, message: "IMAP connection timed out"}
      emit_imap([:manifold, :connectors, :imap, :connect, :stop], connect_start, base_meta, error)
      {:error, error}

    {:error, reason} ->
      error = connect_failed_error(reason)
      emit_imap([:manifold, :connectors, :imap, :connect, :stop], connect_start, base_meta, error)
      {:error, error}
  end
end
```

Wrap `select/1` similarly:

```elixir
def select(conn, mailbox_path) when is_binary(mailbox_path) do
  conn = get_conn(conn)
  start = System.monotonic_time()
  meta = Map.put(imap_conn_meta(conn), :mailbox_path, mailbox_path)

  case command(conn, "SELECT #{quote_mailbox(mailbox_path)}") do
    {:ok, conn, lines} ->
      put_conn(conn)

      case parse_uidvalidity(lines) do
        {:ok, uidvalidity} ->
          emit_imap(
            [:manifold, :connectors, :imap, :select, :stop],
            start,
            Map.put(meta, :uidvalidity, uidvalidity),
            :ok
          )

          {:ok, %{uidvalidity: uidvalidity, uidnext: parse_uidnext(lines)}}

        {:error, %Error{} = error} ->
          emit_imap([:manifold, :connectors, :imap, :select, :stop], start, meta, error)
          {:error, error}
      end

    {:error, %Error{} = error} ->
      emit_imap([:manifold, :connectors, :imap, :select, :stop], start, meta, error)
      {:error, error}
  end
end
```

Add helpers (store optional account_id on conn via process dict already used by `put_conn`, or read from settings only at connect — for select, keep account_id in the process dictionary alongside conn):

```elixir
defp put_conn(conn) do
  Process.put({__MODULE__, :conn}, conn)
  conn
end

# When connecting succeeds, also:
# Process.put({__MODULE__, :activity_meta}, base_meta)

defp imap_base_meta(settings, host, port, tls_mode) do
  %{host: host, port: port, tls_mode: tls_mode, provider: "imap"}
  |> then(fn m ->
    case Map.get(settings, :account_id) do
      id when is_binary(id) -> Map.put(m, :account_id, id)
      _ -> m
    end
  end)
end

defp imap_conn_meta(_conn) do
  Process.get({__MODULE__, :activity_meta}, %{provider: "imap"})
end

defp emit_imap(event, start, meta, :ok) do
  :telemetry.execute(event, %{duration_ms: duration_ms(start)}, Map.put(meta, :result, :ok))
end

defp emit_imap(event, start, meta, %Error{} = error) do
  :telemetry.execute(
    event,
    %{duration_ms: duration_ms(start)},
    meta
    |> Map.put(:result, :error)
    |> Map.put(:error_code, error.code)
    |> Map.put(:error_message, error.message)
  )
end

defp duration_ms(start) do
  System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
end
```

In the success path after `open_and_greet_safe`, call `Process.put({__MODULE__, :activity_meta}, base_meta)` before LOGIN so `select/2` metadata includes `account_id`. Clear it in `logout/1` with `Process.delete({__MODULE__, :activity_meta})`.

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/imap/telemetry_test.exs apps/manifold_connectors/test/manifold/connectors/imap/fake_test.exs apps/manifold_connectors/test/manifold/connectors/imap/client_connect_test.exs apps/manifold_connectors/test/manifold/connectors/imap/client_protocol_test.exs
```

Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add \
  apps/manifold_connectors/lib/manifold/connectors/imap/client.ex \
  apps/manifold_connectors/lib/manifold/connectors/imap/fake.ex \
  apps/manifold_connectors/lib/manifold/connectors/provider/imap.ex \
  apps/manifold_connectors/lib/manifold/connectors/sync.ex \
  apps/manifold_connectors/test/manifold/connectors/imap/telemetry_test.exs
git commit -m "$(cat <<'EOF'
feat(connectors): emit IMAP connect/auth/select telemetry.

EOF
)"
```

---

### Task 4: Emit Sync stop telemetry + Fake IMAP activity integration

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex`
- Test: `apps/manifold_connectors/test/manifold/connectors/activity_log_imap_test.exs`

**Interfaces:**
- Consumes: Handler attached (Application or test `Handler.attach/0`); Fake transport with `account_id` in config
- Produces: `[:manifold, :connectors, :sync, :stop]` with measurements `%{duration_ms, message_count, page_count}` and metadata `%{account_id, provider, result, error_code?, error_message?}`

- [ ] **Step 1: Write failing integration tests**

```elixir
defmodule Manifold.Connectors.ActivityLogImapTest do
  use Manifold.DataCase, async: false

  alias Manifold.Connectors
  alias Manifold.Connectors.ActivityLog
  alias Manifold.Connectors.ActivityLog.Handler
  alias Manifold.Connectors.IMAP.Fake

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    log_dir = Path.join(tmp_dir, "connectors")
    old = snapshot_env()

    Application.put_env(:manifold_connectors, :activity_log_dir, log_dir)
    Application.put_env(:manifold_connectors, :activity_log_retention_days, 14)
    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )
    Application.put_env(:manifold_connectors, :imap_transport, Fake)
    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))

    Handler.detach()
    assert :ok = Handler.attach()

    on_exit(fn ->
      Handler.detach()
      restore_env(old)
    end)

    :ok
  end

  test "successful sync writes sync stop entry with counts" do
    raw =
      "From: sender@example.net\r\nTo: reader@imap-act.example\r\nSubject: hi\r\n\r\nBody\r\n"

    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      uidvalidity: 3,
      messages: [{1, raw}]
    })

    assert {:ok, account} =
             Connectors.create_imap_account(%{
               email_address: "reader@imap-act.example",
               username: "reader@imap-act.example",
               password: "secret",
               host: "imap.example",
               port: 993,
               tls_mode: "ssl"
             })

    assert {:snooze, 1} = Connectors.sync_account(account.id)

    assert {:ok, entries} = ActivityLog.read(account.id, Date.utc_today(), 200)
    sync_entries = Enum.filter(entries, &(&1["event"] == ["manifold", "connectors", "sync", "stop"]))
    assert [%{"measurements" => measurements, "metadata" => meta} | _] = sync_entries
    assert measurements["message_count"] >= 1
    assert measurements["page_count"] == 1
    assert meta["result"] == "ok"
    assert meta["account_id"] == account.id
    assert meta["provider"] == "imap"

    assert Enum.any?(entries, &(&1["event"] == ["manifold", "connectors", "imap", "auth", "stop"]))
  end

  test "auth failure after account exists writes failure summary entry" do
    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      uidvalidity: 1,
      messages: []
    })

    assert {:ok, account} =
             Connectors.create_imap_account(%{
               email_address: "reader@imap-fail-act.example",
               username: "reader@imap-fail-act.example",
               password: "secret",
               host: "imap.example",
               port: 993,
               tls_mode: "ssl"
             })

    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "other",
      uidvalidity: 1,
      messages: []
    })

    assert {:cancel, :reconnect_required} = Connectors.sync_account(account.id)

    assert {:ok, entries} = ActivityLog.read(account.id, Date.utc_today(), 200)

    assert Enum.any?(entries, fn e ->
             e["event"] == ["manifold", "connectors", "imap", "auth", "stop"] and
               e["metadata"]["result"] == "error" and
               e["metadata"]["error_code"] == "auth_failed"
           end)

    assert Enum.any?(entries, fn e ->
             e["event"] == ["manifold", "connectors", "sync", "stop"] and
               e["metadata"]["result"] == "error"
           end)
  end

  defp snapshot_env do
    %{
      activity_log_dir: Application.get_env(:manifold_connectors, :activity_log_dir),
      activity_log_retention_days:
        Application.get_env(:manifold_connectors, :activity_log_retention_days),
      encryption_key: Application.get_env(:manifold_connectors, :encryption_key),
      imap_transport: Application.get_env(:manifold_connectors, :imap_transport),
      imap_fake: Application.get_env(:manifold_connectors, :imap_fake),
      spool_dir: Application.get_env(:manifold_storage, :spool_dir),
      raw_store_dir: Application.get_env(:manifold_storage, :raw_store_dir)
    }
  end

  defp restore_env(old) do
    Enum.each(
      [
        {:manifold_connectors, :activity_log_dir, old.activity_log_dir},
        {:manifold_connectors, :activity_log_retention_days, old.activity_log_retention_days},
        {:manifold_connectors, :encryption_key, old.encryption_key},
        {:manifold_connectors, :imap_transport, old.imap_transport},
        {:manifold_connectors, :imap_fake, old.imap_fake},
        {:manifold_storage, :spool_dir, old.spool_dir},
        {:manifold_storage, :raw_store_dir, old.raw_store_dir}
      ],
      fn {app, key, value} ->
        if is_nil(value), do: :ok, else: Application.put_env(app, key, value)
      end
    )
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/activity_log_imap_test.exs
```

Expected: FAIL — sync stop entries missing (and/or auth failure sync stop missing).

- [ ] **Step 3: Instrument Sync.run**

Restructure `Sync.run/2` so telemetry always fires with known `provider`. Keep the existing `with` body inside `do_run/3`:

```elixir
def run(account_id, opts \\ []) do
  start = System.monotonic_time()
  now = Keyword.get(opts, :now, DateTime.utc_now())

  case do_run(account_id, now, opts) do
    {:ok, provider, message_count, outcome} ->
      emit_sync_stop(account_id, start, provider, :ok, %{
        message_count: message_count,
        page_count: 1
      })

      outcome

    {:error, provider, error, outcome} ->
      emit_sync_stop(account_id, start, provider, error, %{message_count: 0, page_count: 0})
      outcome
  end
rescue
  DBConnection.ConnectionError ->
    emit_sync_stop(account_id, start, "unknown", :database_unavailable, %{
      message_count: 0,
      page_count: 0
    })

    {:error, Error.new(:temporary, :database_unavailable, "connector database is unavailable")}
end

defp do_run(account_id, now, opts) do
  with {:ok, account, cursor} <- begin_sync(account_id, now),
       {:ok, adapter, config} <- runtime(account.provider),
       {:ok, config} <- enrich_runtime_config(account, config),
       {:ok, auth} <- auth_material(account, adapter, config, now, provider_opts(opts)),
       {:ok, %Page{} = page} <-
         sync_page(adapter, auth, cursor, config, provider_opts(opts)),
       messages <- collapse_messages(page.messages),
       :ok <- process_messages(messages, account, adapter, config, auth, now, opts),
       :ok <- maybe_fault(opts, :after_page_before_cursor),
       {:ok, more?} <- checkpoint(account, cursor, page, now) do
    outcome = if more?, do: {:snooze, 1}, else: :ok
    {:ok, account.provider, length(messages), outcome}
  else
    {:error, {:cursor_provider_error, cursor, %ProviderError{} = error}} ->
      {:error, "imap", error, handle_cursor_provider_error(account_id, cursor, error, now)}

    {:error, %ProviderError{} = error} ->
      {:error, "imap", error, handle_provider_error(account_id, error, now)}

    {:error, %Error{} = error} ->
      {:error, "unknown", error, handle_core_error(account_id, error, now)}

    {:error, reason} ->
      error =
        Error.new(:temporary, :sync_failed, "connector synchronization failed", %{
          reason: inspect(reason)
        })

      record_failure(account_id, error.class, error.reason, error.message, now)
      {:error, "unknown", error, {:error, error}}
  end
end
```

For non-IMAP providers later, replace the hard-coded `"imap"` in ProviderError branches with `account.provider` by binding `account` before the failing call (use nested `case` if the `with` else clause cannot see `account`). For v1 IMAP-focused activity, `"imap"` is acceptable when the failure happens after IMAP runtime enrichment.

Add helpers:


```elixir
defp emit_sync_stop(account_id, start, provider, :ok, counts) do
  :telemetry.execute(
    [:manifold, :connectors, :sync, :stop],
    Map.merge(%{duration_ms: duration_ms(start)}, counts),
    %{account_id: account_id, provider: provider, result: :ok}
  )
end

defp emit_sync_stop(account_id, start, provider, %ProviderError{} = error, counts) do
  :telemetry.execute(
    [:manifold, :connectors, :sync, :stop],
    Map.merge(%{duration_ms: duration_ms(start)}, counts),
    %{
      account_id: account_id,
      provider: provider,
      result: :error,
      error_code: error.code,
      error_message: error.message
    }
  )
end

defp emit_sync_stop(account_id, start, provider, %Error{} = error, counts) do
  :telemetry.execute(
    [:manifold, :connectors, :sync, :stop],
    Map.merge(%{duration_ms: duration_ms(start)}, counts),
    %{
      account_id: account_id,
      provider: provider,
      result: :error,
      error_code: error.reason,
      error_message: error.message
    }
  )
end

defp emit_sync_stop(account_id, start, provider, :database_unavailable, counts) do
  :telemetry.execute(
    [:manifold, :connectors, :sync, :stop],
    Map.merge(%{duration_ms: duration_ms(start)}, counts),
    %{
      account_id: account_id,
      provider: provider,
      result: :error,
      error_code: :database_unavailable,
      error_message: "connector database is unavailable"
    }
  )
end

defp duration_ms(start) do
  System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
end
```

Confirm `enrich_runtime_config/2` still includes `account_id: account.id` from Task 3.

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/activity_log_imap_test.exs apps/manifold_connectors/test/manifold/connectors/sync_imap_test.exs
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add \
  apps/manifold_connectors/lib/manifold/connectors/sync.ex \
  apps/manifold_connectors/test/manifold/connectors/activity_log_imap_test.exs
git commit -m "$(cat <<'EOF'
feat(connectors): emit sync stop telemetry into activity logs.

EOF
)"
```

---

### Task 5: Settings Activity LiveView

**Files:**
- Create: `apps/manifold_web/lib/manifold_web/live/external_account_live/activity.ex`
- Modify: `apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex`
- Modify: `apps/manifold_web/lib/manifold_web/router.ex`
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`

**Interfaces:**
- Consumes: `Connectors.get_account/1`, `Connectors.list_activity_dates/1`, `Connectors.read_activity/3`
- Produces: LiveView at `/settings/accounts/:id/activity` with date select, reverse-chronological list, Refresh button; Activity link on accounts index

- [ ] **Step 1: Write failing LiveView tests**

Append to `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs` (reuse existing setup that configures Fake IMAP — ensure activity log dir is tmp for these tests):

```elixir
test "accounts index links to activity page", %{conn: conn} do
  Application.put_env(:manifold_connectors, :imap_fake, %{
    password_expected: "secret",
    messages: [],
    uidvalidity: 1
  })

  assert {:ok, account} =
           Connectors.create_imap_account(%{
             email_address: "activity-link@imap.example",
             username: "activity-link@imap.example",
             password: "secret",
             host: "imap.example",
             port: 993,
             tls_mode: "ssl"
           })

  assert {:ok, view, _html} = live(conn, "/settings/accounts")

  assert has_element?(
           view,
           "#external-account-#{account.id} a[href='/settings/accounts/#{account.id}/activity']"
         )
end

test "activity page loads empty state for today and refresh", %{conn: conn} do
  log_dir = Path.join(System.tmp_dir!(), "manifold-activity-#{System.unique_integer([:positive])}")
  previous = Application.get_env(:manifold_connectors, :activity_log_dir)
  Application.put_env(:manifold_connectors, :activity_log_dir, log_dir)
  on_exit(fn -> Application.put_env(:manifold_connectors, :activity_log_dir, previous) end)

  Application.put_env(:manifold_connectors, :imap_fake, %{
    password_expected: "secret",
    messages: [],
    uidvalidity: 1
  })

  assert {:ok, account} =
           Connectors.create_imap_account(%{
             email_address: "activity-empty@imap.example",
             username: "activity-empty@imap.example",
             password: "secret",
             host: "imap.example",
             port: 993,
             tls_mode: "ssl"
           })

  assert {:ok, view, html} = live(conn, ~p"/settings/accounts/#{account.id}/activity")
  assert html =~ "Activity"
  assert html =~ account.email_address
  assert has_element?(view, "#activity-empty")
  assert has_element?(view, "#activity-refresh")
  assert has_element?(view, "#activity-date")

  html = view |> element("#activity-refresh") |> render_click()
  assert html =~ "No activity"
end

test "activity page shows entries for selected date", %{conn: conn} do
  log_dir = Path.join(System.tmp_dir!(), "manifold-activity-#{System.unique_integer([:positive])}")
  previous = Application.get_env(:manifold_connectors, :activity_log_dir)
  Application.put_env(:manifold_connectors, :activity_log_dir, log_dir)
  on_exit(fn -> Application.put_env(:manifold_connectors, :activity_log_dir, previous) end)

  Application.put_env(:manifold_connectors, :imap_fake, %{
    password_expected: "secret",
    messages: [],
    uidvalidity: 1
  })

  assert {:ok, account} =
           Connectors.create_imap_account(%{
             email_address: "activity-list@imap.example",
             username: "activity-list@imap.example",
             password: "secret",
             host: "imap.example",
             port: 993,
             tls_mode: "ssl"
           })

  assert :ok =
           Manifold.Connectors.ActivityLog.append(account.id, %{
             "event" => ["manifold", "connectors", "imap", "auth", "stop"],
             "timestamp" => "2026-08-06T12:00:00.000000Z",
             "measurements" => %{"duration_ms" => 5},
             "metadata" => %{
               "account_id" => account.id,
               "result" => "error",
               "error_code" => "auth_failed",
               "error_message" => "IMAP authentication failed"
             }
           })

  assert {:ok, view, html} = live(conn, ~p"/settings/accounts/#{account.id}/activity")
  assert html =~ "auth"
  assert html =~ "auth_failed"
  assert html =~ "IMAP authentication failed"
  refute html =~ "password"
  assert has_element?(view, "#activity-entries")
end

test "activity page redirects for unknown account id", %{conn: conn} do
  missing = Ecto.UUID.generate()

  assert {:error, {:live_redirect, %{to: "/settings/accounts"}}} =
           live(conn, ~p"/settings/accounts/#{missing}/activity")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
devenv shell -- mix test apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: FAIL — route / LiveView module missing; Activity link missing.

- [ ] **Step 3: Add route**

In `apps/manifold_web/lib/manifold_web/router.ex` inside `live_session :local_instance`, after the accounts routes:

```elixir
live("/settings/accounts", ExternalAccountLive.Index, :index)
live("/settings/accounts/new", ExternalAccountLive.New, :new)
live("/settings/accounts/:id/activity", ExternalAccountLive.Activity, :show)
```

- [ ] **Step 4: Add Activity link on index**

In `index.ex` actions cell, add before the sync button:

```heex
<.link
  id={"activity-#{account.id}"}
  navigate={~p"/settings/accounts/#{account.id}/activity"}
  class="settings-icon-button"
  title="Activity"
  aria-label={"Activity for #{account.email_address}"}
>
  <.dm_mdi name="history" />
  <span class="sr-only">Activity</span>
</.link>
```

Update the index-link test is already using the href-only selector above.

- [ ] **Step 5: Implement Activity LiveView**

Create `apps/manifold_web/lib/manifold_web/live/external_account_live/activity.ex`:

```elixir
defmodule ManifoldWeb.ExternalAccountLive.Activity do
  use ManifoldWeb, :live_view

  alias Manifold.Connectors

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    case Connectors.get_account(id) do
      {:ok, account} ->
        today = Date.utc_today()

        {:ok,
         socket
         |> assign(
           page_title: "Account activity",
           account: account,
           selected_date: today,
           available_dates: available_dates(account.id, today),
           entries: load_entries(account.id, today)
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "External account not found.")
         |> push_navigate(to: ~p"/settings/accounts")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("select_date", %{"date" => date_string}, socket) do
    date =
      case Date.from_iso8601(date_string) do
        {:ok, date} -> date
        _ -> socket.assigns.selected_date
      end

    account_id = socket.assigns.account.id

    {:noreply,
     assign(socket,
       selected_date: date,
       available_dates: available_dates(account_id, date),
       entries: load_entries(account_id, date)
     )}
  end

  def handle_event("refresh", _params, socket) do
    account_id = socket.assigns.account.id
    date = socket.assigns.selected_date

    {:noreply,
     assign(socket,
       available_dates: available_dates(account_id, date),
       entries: load_entries(account_id, date)
     )}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section id="account-activity">
      <div class="settings-heading">
        <div>
          <h1>Activity</h1>
          <p class="settings-intro">
            Connection and sync events for {@account.email_address}.
          </p>
        </div>
        <div class="settings-heading-actions">
          <.link navigate={~p"/settings/accounts"} class="settings-action">
            Back to accounts
          </.link>
          <button
            id="activity-refresh"
            type="button"
            class="settings-action"
            phx-click="refresh"
          >
            Refresh
          </button>
        </div>
      </div>

      <form phx-change="select_date" id="activity-date-form">
        <label for="activity-date">Date</label>
        <select id="activity-date" name="date">
          <option
            :for={date <- @available_dates}
            value={Date.to_iso8601(date)}
            selected={date == @selected_date}
          >
            {Date.to_iso8601(date)}
          </option>
        </select>
      </form>

      <div :if={@entries == []} id="activity-empty" class="settings-empty">
        No activity for this day.
      </div>

      <ol :if={@entries != []} id="activity-entries" class="activity-entries">
        <li :for={entry <- @entries} class="activity-entry">
          <time>{entry["timestamp"]}</time>
          <strong>{event_label(entry["event"])}</strong>
          <span class={"activity-result result-#{entry_result(entry)}"}>
            {entry_result(entry)}
          </span>
          <span :if={entry_error(entry)} class="settings-error">{entry_error(entry)}</span>
          <span class="settings-secondary">{duration_label(entry)}</span>
        </li>
      </ol>
    </section>
    """
  end

  defp available_dates(account_id, selected) do
    dates =
      case Connectors.list_activity_dates(account_id) do
        {:ok, dates} -> dates
        _ -> []
      end

    [selected | dates]
    |> Enum.uniq()
    |> Enum.sort({:desc, Date})
  end

  defp load_entries(account_id, date) do
    case Connectors.read_activity(account_id, date) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  defp event_label(event) when is_list(event), do: Enum.join(event, ".")
  defp event_label(_), do: "unknown"

  defp entry_result(%{"metadata" => %{"result" => result}}) when is_binary(result), do: result
  defp entry_result(_), do: "unknown"

  defp entry_error(%{"metadata" => %{"error_message" => message}}) when is_binary(message),
    do: message

  defp entry_error(%{"metadata" => %{"error_code" => code}}) when is_binary(code), do: code
  defp entry_error(_), do: nil

  defp duration_label(%{"measurements" => %{"duration_ms" => ms}}) when is_integer(ms),
    do: "#{ms} ms"

  defp duration_label(_), do: nil
end
```

Use `push_navigate/2` in mount as shown. The unknown-account LiveView test expects:

```elixir
assert {:error, {:live_redirect, %{to: "/settings/accounts"}}} =
         live(conn, ~p"/settings/accounts/#{missing}/activity")
```

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
devenv shell -- mix test apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: PASS

Also run connectors activity suite:

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/activity_log_test.exs apps/manifold_connectors/test/manifold/connectors/activity_log/handler_test.exs apps/manifold_connectors/test/manifold/connectors/activity_log_imap_test.exs apps/manifold_connectors/test/manifold/connectors/imap/telemetry_test.exs
```

Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add \
  apps/manifold_web/lib/manifold_web/live/external_account_live/activity.ex \
  apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex \
  apps/manifold_web/lib/manifold_web/router.ex \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
git commit -m "$(cat <<'EOF'
feat(web): add connector account activity LiveView.

EOF
)"
```

---

## Self-Review

### Spec coverage

| Spec requirement | Task |
| --- | --- |
| Emit imap connect/auth/select `:stop` | Task 3 |
| Emit sync `:stop` with duration + counts | Task 4 |
| Handler attach at Connectors Application start | Task 2 |
| JSONL under `log/connectors/<account_id>/YYYY-MM-DD.log` | Task 1–2 |
| Config `:activity_log_dir`, `:activity_log_retention_days` (14) | Task 1 |
| `list_activity_dates/1`, `read_activity/3` | Task 1 |
| LiveView `/settings/accounts/:id/activity` + index link | Task 5 |
| Never log passwords; write only with account_id | Task 2–3 |
| Skip write without account_id; pre-create stays on form | Task 2 (+ existing create path unchanged) |
| Path traversal / non-UUID rejected | Task 1 |
| Retention deletes old day files | Task 1–2 |
| Bad JSON skipped on read | Task 1 |
| Fake IMAP auth failure + successful sync entries | Task 4 |
| LiveView empty / populated / invalid account | Task 5 |
| Manual refresh; no PubSub v1 | Task 5 |
| Out of scope left out (DB dual-write, cross-account, per-message fetch lines) | — |

### Placeholder scan

No TBD/TODO left. Sync instrumentation is the single `do_run/3` return-tuple form in Task 4.

### Type consistency

- Account id: UUID string throughout
- API: `{:ok, [Date.t()]}` / `{:ok, [map()]}` / `{:error, :invalid_account_id}`
- Telemetry measurements: `duration_ms` integer; sync also `message_count`, `page_count`
- Metadata `result`: atom `:ok` / `:error` at emit; string in JSONL
- Event names match spec lists exactly
