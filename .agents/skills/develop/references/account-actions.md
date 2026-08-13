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
configured with concurrency `1` per Oban producer/node, not as a cluster-global
limit. Its only argument is the opaque `%{"purge_id" => purge_id}`; account
addresses, delivery IDs, message IDs, and object keys are never put in job
arguments. One incomplete job is unique by worker and `purge_id`, and each
request transaction persists the inactive purge marker, connector quiescence,
purge record, and Oban job atomically.

## Purge stages and bounds

The persisted stage order is:

`discover` -> `drain` -> `outbound` -> `connectors` -> `mailbox_copy` ->
`orphan_payloads` -> `objects` -> `finalize` -> `completed`.

Each stage execution selects no more than 250 primary candidates or work rows
and persists its cursor/work before snoozing. Limit lookahead, dependent rows,
reference and metadata queries, cascading rows, and outbox rows are additional
database operations rather than primary batch candidates. `orphan_payloads`
processes one delivery candidate per execution and pages at most 248 attachment
keys at a time. Finalize repeats discovery and job drain, verifies every owning
context and pending work table, and routes any remaining foreign-key ownership
back to its cleanup stage instead of forcing deletion.

The drain deletes bounded non-executing connector and outbound jobs instead of
retaining cancelled rows. An executing job is cancelled first and forces a
five-second snooze; a later bounded pass deletes that cancelled row before any
destructive account-data stage. Outbound data is purged before connector send
methods because provider-submission snapshots retain a foreign key to the
selected send method.

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

Inspect jobs at `/jobs` and filter Queue to `account_purge`. Production commands
must target the already-running main `manifold` release with `bin/manifold rpc`;
do not use `mix run`, which would boot another application and Oban instance.
Run these commands from the extracted release directory on a release node.

List recent purge records without loading account or message content:

```bash
bin/manifold rpc 'import Ecto.Query; alias Manifold.AccountLifecycle.Schema.AccountPurge; AccountPurge |> order_by([p], desc: p.inserted_at) |> limit(20) |> select([p], map(p, [:id, :mailbox_id, :status, :stage, :error_class, :error_code, :discovered_deliveries, :purged_deliveries, :shared_retained_deliveries, :deleted_objects, :updated_at])) |> Manifold.Repo.all() |> IO.inspect(pretty: true)'
```

Inspect the dedicated queue from the same environment:

```bash
bin/manifold rpc 'Manifold.Data.ObanJobs.list_jobs(%{queue: "account_purge", limit: 50}) |> Enum.map(&Map.take(&1, [:id, :state, :queue, :args, :attempt, :max_attempts, :scheduled_at])) |> IO.inspect(pretty: true)'
```

Before retrying a failed purge, inspect any retained matching worker jobs by the
opaque purge ID. A terminal job may already have been pruned, so no matching row
is not an error. Replace the example UUID inside each expression; a caller
environment variable is not visible inside the running release node:

```bash
bin/manifold rpc 'import Ecto.Query; purge_id = "00000000-0000-0000-0000-000000000000"; Oban.Job.query(worker: Manifold.AccountLifecycle.Jobs.PurgeAccount, args: %{"purge_id" => purge_id}) |> order_by([job], desc: job.id) |> Oban.all_jobs() |> Enum.map(&Map.take(&1, [:id, :state, :attempt, :max_attempts, :scheduled_at])) |> IO.inspect(pretty: true)'
```

If the exact prior job is `executing`, wait for it to reach a terminal state;
do not cancel it merely to make uniqueness pass. For one exact `suspended` job,
choose one recovery path. Each mutation carries both the loaded job ID and
`state: :suspended` into the database update; if the state changes concurrently,
the required `{:ok, 1}` match fails closed. Either cancel that exact job safely:

```bash
bin/manifold rpc 'purge_id = "00000000-0000-0000-0000-000000000000"; jobs = Oban.Job.query(worker: Manifold.AccountLifecycle.Jobs.PurgeAccount, args: %{"purge_id" => purge_id}, state: :suspended) |> Oban.all_jobs(); case jobs do [%Oban.Job{id: id}] -> query = Oban.Job.query(id: id, state: :suspended); {:ok, 1} = Oban.cancel_all_jobs(query); %Oban.Job{state: "cancelled"} = Manifold.Repo.get!(Oban.Job, id); IO.inspect(%{id: id, state: "cancelled"}); [] -> raise "no suspended purge job found"; _ -> raise "multiple suspended purge jobs found" end'
```

Or make that exact suspended job available and let the worker take it to a
terminal state:

```bash
bin/manifold rpc 'purge_id = "00000000-0000-0000-0000-000000000000"; jobs = Oban.Job.query(worker: Manifold.AccountLifecycle.Jobs.PurgeAccount, args: %{"purge_id" => purge_id}, state: :suspended) |> Oban.all_jobs(); case jobs do [%Oban.Job{id: id}] -> query = Oban.Job.query(id: id, state: :suspended); {:ok, 1} = Oban.retry_all_jobs(query); IO.inspect(%{id: id, action: :made_available}); [] -> raise "no suspended purge job found"; _ -> raise "multiple suspended purge jobs found" end'
```

Before calling the lifecycle retry API, verify that the purge has no job in an
incomplete state. `Oban.Job.query/1` coerces the incomplete state list for the
database query. If the resumed job is still incomplete, wait and rerun this
command. An empty result, including when terminal jobs were pruned, passes this
check; the lifecycle API still enforces locked failed status and job uniqueness:

```bash
bin/manifold rpc 'purge_id = "00000000-0000-0000-0000-000000000000"; incomplete = Oban.Job.query(worker: Manifold.AccountLifecycle.Jobs.PurgeAccount, args: %{"purge_id" => purge_id}, state: Oban.Job.unique_states(:incomplete)) |> Oban.all_jobs(); case incomplete do [] -> IO.inspect(%{incomplete_jobs: 0}); active -> active |> Enum.map(&Map.take(&1, [:id, :state])) |> then(&raise("purge job is still incomplete: #{inspect(&1)}")) end'
```

Only then retry a purge whose durable status is `failed` (the UI retry button
calls the same API):

```bash
bin/manifold rpc 'purge_id = "00000000-0000-0000-0000-000000000000"; case Manifold.Repo.get(Manifold.AccountLifecycle.Schema.AccountPurge, purge_id) do %{status: "failed"} -> case Manifold.AccountLifecycle.retry_deletion(purge_id) do {:ok, purge} -> IO.inspect(%{purge_id: purge.id, status: purge.status, stage: purge.stage}); {:error, reason} -> raise "purge retry failed: #{inspect(reason)}" end; nil -> raise "purge not found"; purge -> raise "purge is not failed: #{purge.status}" end'
```

Retry resumes the existing purge ID, stage, and work state. It does not create a
second purge or reactivate the mailbox. Never insert a replacement purge job or
edit purge/job status directly; use only the exact-job Oban operations above
and `Manifold.AccountLifecycle.retry_deletion/1`.

## Configuration, scope, and rollback

- `config/config.exs` configures `account_purge: 1`; test mode keeps Oban queues
  disabled and uses manual job execution.
- The main `manifold` release includes `manifold_account_lifecycle` permanently.
- `manifold_edge` does not include the lifecycle app. No edge purge protocol or
  remote edge deletion is introduced.
- Remote provider deletion and authorization revocation remain explicitly out
  of scope.
- Before a rollback, publish a queue pause. In Oban 2.23.1, `local_only`
  defaults to `false`, so the notification is scoped by the configured database
  prefix and carries `ident: :any` for every matching `account_purge` producer.
  Successful publication is not an acknowledgement from each node:

  ```bash
  bin/manifold rpc ':ok = Oban.pause_queue(queue: :account_purge); IO.inspect(:account_purge_pause_broadcast)'
  ```

  Execute the following local check with `bin/manifold rpc` on every main-release
  node and require `paused: true` from each one before proceeding:

  ```bash
  bin/manifold rpc 'case Oban.check_queue(queue: :account_purge) do %{paused: true} = queue -> queue |> Map.take([:node, :queue, :paused, :running]) |> IO.inspect(pretty: true); nil -> raise "account_purge producer is not running on this node"; queue -> raise "account_purge producer is not paused on this node: #{inspect(Map.take(queue, [:node, :queue, :paused, :running]))}" end'
  ```

  Pausing prevents new execution but does not stop a job that is already
  executing. After every node acknowledges the pause, re-run this database-wide
  check until it reports zero jobs:

  ```bash
  bin/manifold rpc 'jobs = Oban.Job.query(queue: :account_purge, state: :executing) |> Oban.all_jobs(); case jobs do [] -> IO.inspect(%{executing: 0}); jobs -> jobs |> Enum.map(&Map.take(&1, [:id, :state, :args])) |> then(&raise("account purge jobs are still executing: #{inspect(&1)}")) end'
  ```

  Schema rollback is prohibited while any purge is not `completed`. This
  includes a `failed` purge, which may already have removed part of the local
  account data. The check fails closed for every non-completed purge:

  ```bash
  bin/manifold rpc 'import Ecto.Query; alias Manifold.AccountLifecycle.Schema.AccountPurge; purges = AccountPurge |> where([purge], purge.status != "completed") |> select([purge], map(purge, [:id, :mailbox_id, :status, :stage, :updated_at])) |> Manifold.Repo.all(); case purges do [] -> IO.inspect(%{non_completed_purges: 0}); purges -> IO.inspect(purges, pretty: true); raise "schema rollback prohibited: every account purge must be completed" end'
  ```

  Do not reactivate mailboxes or edit purge state to bypass the check. Retry and
  finish every failed or incomplete purge before schema rollback. If rollback
  is aborted, first confirm that the deployed code and schema remain compatible,
  then publish a resume signal:

  ```bash
  bin/manifold rpc ':ok = Oban.resume_queue(queue: :account_purge); IO.inspect(:account_purge_resume_broadcast)'
  ```

  Resume publication is also not a per-node acknowledgement. On every
  main-release node, require `paused: false` before returning the system to
  service:

  ```bash
  bin/manifold rpc 'case Oban.check_queue(queue: :account_purge) do %{paused: false} = queue -> queue |> Map.take([:node, :queue, :paused, :running]) |> IO.inspect(pretty: true); nil -> raise "account_purge producer is not running on this node"; queue -> raise "account_purge producer is still paused on this node: #{inspect(Map.take(queue, [:node, :queue, :paused, :running]))}" end'
  ```

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
