# Mail Sync Button Job UI

2026-10-21: the engine and telemetry now use Styx; see the
[migration record](styx-migration.md). The historical filename/spec are retained.

## Behavior

Mail sidebar Sync enqueues `Connectors.enqueue_sync/1`. While an incomplete
`Manifold.Connectors.Jobs.SyncAccount` Styx job exists for the mailbox receive
method, the button is disabled and the sync icon rotates.

## Ownership

- `Manifold.Connectors.sync_job_running?/1` — incomplete Styx job query
- `ManifoldWeb.SyncNotifier` — Styx job telemetry → PubSub `connector_sync:<id>`
- `ManifoldWeb.MailLive.Index` — `syncing` assign, subscribe, button UI
- Spec: `docs/superpowers/specs/2026-08-07-mail-sync-button-oban-ui-design.md`

## Notes

- Account LiveView Sync button is not wired to this UI yet
- Mount/params always re-query Styx; PubSub covers live updates including cron starts
