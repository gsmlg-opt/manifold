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

    assert {:error, :enoent} = File.ls(log_dir)
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

  test "sync message stop appends per-message activity", %{account_id: account_id} do
    :telemetry.execute(
      [:manifold, :connectors, :sync, :message, :stop],
      %{duration_ms: 42},
      %{
        account_id: account_id,
        provider: "imap",
        provider_message_id: "imap:3:9",
        result: :ok,
        password: "secret",
        raw_body: "From: x\r\n\r\nsecret"
      }
    )

    assert {:ok, [entry]} = ActivityLog.read(account_id, Date.utc_today())
    assert entry["event"] == ["manifold", "connectors", "sync", "message", "stop"]
    assert entry["measurements"]["duration_ms"] == 42
    assert entry["metadata"]["provider_message_id"] == "imap:3:9"
    assert entry["metadata"]["result"] == "ok"
    refute Map.has_key?(entry["metadata"], "password")
    refute Map.has_key?(entry["metadata"], "raw_body")
  end

  defp restore(_key, nil), do: :ok
  defp restore(key, value), do: Application.put_env(:manifold_connectors, key, value)
end
