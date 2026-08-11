# Account disable and asynchronous local deletion

## Feature

- **Name**: Account lifecycle actions
- **Date**: 2026-08-11
- **Owner/Requestor**: Manifold Accounts
- **Status**: done

## User-facing behavior

The account table is served at `/settings/accounts` by
`ManifoldWeb.AccountLive.Index`. Each normal row uses icon-only controls whose
DuskMoon tooltip content exactly matches its accessible label:

| Action | Icon | Tooltip and `aria-label` |
| --- | --- | --- |
| Edit | `pencil-outline` | Edit account |
| Manage | `cog-outline` | Manage account |
| Disable | `account-off-outline` | Disable account |
| Delete | `delete-outline` | Delete account |

Disable immediately makes the mailbox inactive, quiesces its connectors, and
retains its local data. The row remains visible as **Disabled**; Edit, Manage,
and Delete remain available, while Disable is omitted. Re-enable behavior is
not part of this feature.

Delete opens an accessible typed-confirmation dialog. The submitted value must
match the trimmed, full current address. `Manifold.Accounts.begin_purge/4`
locks and freshly loads the mailbox and domain before recomputing the expected
address, so the socket's displayed address is never authoritative. A mismatch
changes no state and enqueues no job.

After a valid request, the account is inactive and the row shows
`aria-live="polite"` **Deleting...** with no account actions. The LiveView polls
every five seconds only while a displayed purge is `requested` or `running`.
A durable failure shows **Delete failed** with the **Retry account deletion**
action. Completion deletes the mailbox row, so the next refresh removes it from
the table. The completed `account_purges` record retains only opaque IDs,
timestamps, stage/status, and aggregate counters; transient delivery/object
work rows are removed.

Deletion is local-only. It removes data stored by this Manifold installation
for the selected account. It does not delete a provider account or provider
mail, revoke OAuth authorization, or otherwise mutate Gmail, Microsoft, IMAP,
EAS, or another remote system.

## Lifecycle ownership and queue

The `manifold_account_lifecycle` umbrella app owns purge schemas, atomic
request/enqueue and retry orchestration, the Oban worker, persisted stage
progress, error classification, and final completion. Existing contexts retain
ownership of their own write fences and cleanup operations.

`Manifold.AccountLifecycle.Jobs.PurgeAccount` runs on the `account_purge` queue,
configured with concurrency `1`. Its only argument is the opaque
`%{"purge_id" => purge_id}`; account addresses, delivery IDs, message IDs, and
object keys are never put in job arguments. One incomplete job is unique by
worker and `purge_id`, and each request transaction persists the inactive purge
marker, connector quiescence, purge record, and Oban job atomically.

## Purge stages and bounds

The persisted stage order is:

`discover` -> `drain` -> `connectors` -> `outbound` -> `mailbox_copy` ->
`orphan_payloads` -> `objects` -> `finalize` -> `completed`.

Each worker execution handles no more than 250 database work items and persists
its cursor/work before snoozing. Attachment discovery uses pages of 248 keys so
each page remains within the 250-item bound. Finalize repeats discovery and job
drain, verifies every owning context and pending work table, and routes any
remaining foreign-key ownership back to its cleanup stage instead of forcing
deletion.

## Mailbox-copy and shared-delivery rule

A delivery sent to multiple accounts gives each account its own mailbox-facing
copy: mailbox entries, recipient links, folders, and thread membership are
scoped to that mailbox. Purging one account removes only those target-mailbox
rows. Before deleting an inbound delivery or parsed/security payload, the
coordinator rechecks ownership through Mail, Ingest, and Connectors. Any
remaining mailbox or connector reference marks the candidate
`shared_retained`; the shared delivery and every other account's copy remain.

Only an orphaned delivery is removed. Attachment keys may be persisted across
multiple transactions of at most 248 keys while the delivery remains present
and pending. On the final attachment page, the remaining attachment candidates,
locked orphan-delivery deletion, raw and spool outbox insertion, and candidate
transition to `purged` commit atomically. External deletion begins later in the
objects stage.

## Object outbox and idempotence

`account_purge_objects` is the durable local-deletion outbox for `raw`, `blob`,
`spool`, and `activity_log` work. The objects stage processes at most 250
pending rows, rechecks database references for raw, blob, and spool data, and
marks a still-referenced object complete without deleting it. Blob publication
and deletion use the same per-object-key advisory lock, preventing deletion
from racing a projection commit.

Successful deletion and a missing local file are both successful idempotent
outcomes. A retryable failure increments the persisted attempt count and stores
only a bounded generic error. Permanent key/path validation failures move the
purge to the durable failed state; no failure path reactivates the mailbox.

## API and file ownership

| Owner | Public contract / implementation file |
| --- | --- |
| Data | Purge tables and cleanup indexes in `apps/manifold_data/priv/repo/migrations`; queue visibility in `Manifold.Data.ObanJobs` |
| Accounts | `disable_account/1,2`, `active_account_for_update/2`, `begin_purge/4`, and `delete_purging_account/2` in `apps/manifold_accounts/lib/manifold/accounts.ex` |
| Account lifecycle | `disable_account/1`, `request_deletion/2`, `retry_deletion/1`, and `states_by_mailbox/1` in `apps/manifold_account_lifecycle/lib/manifold/account_lifecycle.ex`; stage engine in `purge.ex`; worker in `jobs/purge_account.ex` |
| Connectors | `quiesce_account/2`, account job drain/discovery/ownership, `purge_account_batch/3`, and residual checks in `apps/manifold_connectors/lib/manifold/connectors.ex`; activity-log deletion in `activity_log.ex` |
| Ingest | Delivery discovery/ownership, job drain, mailbox-link cleanup, locked orphan deletion, object-reference checks, and residual checks in `apps/manifold_ingest/lib/manifold/ingest.ex` |
| Mail | Delivery discovery/ownership, mailbox-entry cleanup, attachment paging, blob reference/key locking, and residual checks in `apps/manifold_mail/lib/manifold/mail.ex`; publication locking in `manifold/mail/projector.ex` |
| Outbound | In-transaction sender fence, account job drain, bounded cleanup, and residual checks in `apps/manifold_outbound/lib/manifold/outbound.ex` |
| Storage | Idempotent public deletion in `Manifold.Storage.RawStore`, `BlobStore`, and `Spool` under `apps/manifold_storage/lib/manifold/storage` |
| Web | Icon actions, fresh confirmation dialog, lifecycle state rendering, retry, and conditional polling in `apps/manifold_web/lib/manifold_web/live/account_live/index.ex`; token-based layout in `assets/css/app.css` |

## Operations and recovery

Inspect jobs at `/jobs` and filter Queue to `account_purge`. From a release-aware
shell, list recent purge records without loading account or message content:

```bash
devenv shell -- mix run -e 'import Ecto.Query; alias Manifold.AccountLifecycle.Schema.AccountPurge; AccountPurge |> order_by([p], desc: p.inserted_at) |> limit(20) |> select([p], map(p, [:id, :mailbox_id, :status, :stage, :error_class, :error_code, :discovered_deliveries, :purged_deliveries, :shared_retained_deliveries, :deleted_objects, :updated_at])) |> Manifold.Repo.all() |> IO.inspect(pretty: true)'
```

Inspect the dedicated queue from the same environment:

```bash
devenv shell -- mix run -e 'Manifold.Data.ObanJobs.list_jobs(%{queue: "account_purge", limit: 50}) |> Enum.map(&Map.take(&1, [:id, :state, :queue, :args, :attempt, :max_attempts, :scheduled_at])) |> IO.inspect(pretty: true)'
```

Retry only a purge whose durable status is `failed` (the UI retry button calls
the same API):

```bash
MANIFOLD_PURGE_ID=00000000-0000-0000-0000-000000000000 devenv shell -- mix run -e 'IO.inspect(Manifold.AccountLifecycle.retry_deletion(System.fetch_env!("MANIFOLD_PURGE_ID")))'
```

Retry resumes the existing purge ID, stage, and work state. It does not create a
second purge or reactivate the mailbox. If the prior job is still executing,
wait for it to finish and then retry. A suspended prior job requires operator
action before retry can persist a replacement job.

## Configuration, scope, and rollback

- `config/config.exs` configures `account_purge: 1`; test mode keeps Oban queues
  disabled and uses manual job execution.
- The main `manifold` release includes `manifold_account_lifecycle` permanently.
- `manifold_edge` does not include the lifecycle app. No edge purge protocol or
  remote edge deletion is introduced.
- Remote provider deletion and authorization revocation remain explicitly out
  of scope.
- Rollback requires stopping the `account_purge` queue before reverting code or
  schema. Do not reactivate mailboxes with an incomplete purge; inspect and
  finish or deliberately recover their durable local work first.

## Validation

- Affected apps: Data, Accounts, Account Lifecycle, Storage, Mail, Outbound,
  Ingest, Connectors, and Web.
- Affected-app verification: 520 tests, 0 failures.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `mix duskmoon_bundler.js.check`, and `mix assets.build` exited successfully.
  The JavaScript check reported two unchanged unused-catch-parameter warnings
  in `apps/manifold_web/assets/js/app.js` and no errors.
- The required full umbrella run passed 596 tests in 14 apps with 0 failures,
  then stopped before `manifold_edge` tests in its out-of-scope test setup. The
  edge helper ignored `TEST_DATABASE_URL`, selected the absent worktree socket
  `/run/user/1000/devenv-a85b80d/postgres`, and
  `Ecto.Adapters.Postgres.storage_up/1` returned `{:error, "killed"}`. That
  unhandled value caused `CaseClauseError` at
  `apps/manifold_edge/test/test_helper.exs:32`, before repository startup or any
  edge tests. No out-of-scope edge code was changed or rerun.

## Follow-ups

- None. Provider-side deletion/revocation, re-enable behavior, and an edge purge
  protocol require separate product designs.
