# Mail Sync Button Oban UI Design

**Date:** 2026-08-07  
**Status:** Approved for planning  
**Scope:** Mail LiveView sidebar Sync button — Oban-driven disabled state + icon rotate while a sync job is incomplete

## Goal

When the user clicks **Sync** in the Mail UI:

1. Enqueue the existing Oban `Manifold.Connectors.Jobs.SyncAccount` job (already via `Connectors.enqueue_sync/1`).
2. While any incomplete Oban sync job exists for that receive method, disable the Sync button and show a rotating sync icon.
3. Re-enable the button when no incomplete job remains.

## Decisions

| Decision | Choice |
| --- | --- |
| Truth source for “syncing” | Oban job incomplete states (`available`, `scheduled`, `executing`, `retryable`, `suspended`) |
| UI update path | PubSub via Oban job telemetry notifier (plus mount-time query) |
| Immediate click UX | Set `syncing` true as soon as enqueue succeeds (covers queue wait before `:start`) |
| Out of scope | Account LiveView sync button; end-to-end IMAP/EAS sync tests |

## Architecture

```text
Click Sync
  → Connectors.enqueue_sync(receive_method_id)
  → LiveView assigns syncing: true (disabled + rotate)

Oban [:oban, :job, :start | :stop | :exception]
  → ManifoldWeb.SyncNotifier (filters SyncAccount)
  → re-check Connectors.sync_job_running?(id)
  → PubSub "connector_sync:<external_account_id>"
  → {:sync_job_changed, account_id, running?}
  → LiveView updates syncing

Mount / mailbox change
  → Connectors.sync_job_running?(id)
  → assign syncing
  → subscribe SyncNotifier topic for that receive method
```

### Components

1. **`Connectors.sync_job_running?/1`**  
   Public query extracted from the incomplete-job lookup already used by `ensure_sync_job/2`.

2. **`ManifoldWeb.SyncNotifier`**  
   GenServer patterned after `MailNotifier`:
   - Attach Oban telemetry `[:oban, :job, :start]`, `[:oban, :job, :stop]`, `[:oban, :job, :exception]`.
   - Filter `worker == "Manifold.Connectors.Jobs.SyncAccount"`.
   - Read `external_account_id` from job args.
   - Broadcast after `sync_job_running?/1` so retries keep `running? = true`.
   - Started under `ManifoldWeb.Application`.

3. **`MailLive.Index`**
   - Assign `:syncing` and optionally `:sync_receive_method_id`.
   - On sync click: enqueue → flash → `syncing: true`.
   - Subscribe/unsubscribe `connector_sync:<id>` when mailbox (and thus receive method) changes.
   - Handle `{:sync_job_changed, id, running?}` for the current method only.
   - Button: `disabled={@syncing}`, icon class includes rotate when syncing.

4. **CSS**  
   `.sync-button.is-syncing .mail-icon` (or equivalent) with `@keyframes` rotate; respect `prefers-reduced-motion` if the design system already does.

## Error handling & edge cases

| Case | Behavior |
| --- | --- |
| Enqueue failure / no enabled method | Existing error flash; `syncing` stays false |
| Unique job reuse | Same as new enqueue: `syncing` true |
| Job exception then retry | Notifier re-queries; stay syncing while incomplete |
| Job permanently done | `running?` false; button enabled |
| Multi-tab LiveViews | Shared PubSub topic updates all subscribers |
| Mailbox switch | Unsubscribe old topic; query + subscribe for new method |
| Notifier down / missed event | Mount/params query is the fallback |
| Cron/background enqueue while page open | Oban `:start` broadcast disables the button |

## Testing

### Connectors

- `sync_job_running?/1` false with no incomplete job; true when an incomplete `SyncAccount` job exists for that id.

### SyncNotifier

- `SyncAccount` `:start` → broadcast with `running?` true (or true after query).
- `:stop` / `:exception` with no incomplete job → `running?` false; with remaining incomplete → true.
- Non-`SyncAccount` workers ignored.

### Mail LiveView

- Click Sync → queued flash, disabled button, rotating icon class.
- `{:sync_job_changed, id, false}` for current method → button enabled again.
- Mount with existing incomplete job → initially disabled + rotating.
- Enqueue failure → not disabled.

### Explicitly not in this change

- Real provider sync E2E.
- Account page Sync button UI parity.

## File touch list (expected)

- `apps/manifold_connectors/lib/manifold/connectors.ex` (+ tests)
- `apps/manifold_web/lib/manifold_web/sync_notifier.ex` (new) (+ tests)
- `apps/manifold_web/lib/manifold_web/application.ex`
- `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex`
- `apps/manifold_web/assets/css/app.css`
- `apps/manifold_web/test/manifold_web/mail_live_test.exs`
- `.agents/skills/develop/references/mail-sync-button-oban-ui.md` (post-implement skill note)

## Success criteria

- Clicking Sync queues Oban sync and immediately shows disabled + rotating icon.
- Button stays disabled for the whole incomplete Oban lifetime (queue + execute + retry).
- Button re-enables when no incomplete sync job remains, including after refresh/navigation.
