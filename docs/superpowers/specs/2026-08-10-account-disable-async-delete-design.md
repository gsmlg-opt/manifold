# Account Disable and Asynchronous Local Deletion Design

**Date:** 2026-08-10
**Status:** Approved for planning
**Scope:** Account settings table actions, account disablement, and durable asynchronous deletion of data stored by this Manifold installation

## Goal

Add compact account lifecycle controls to `/settings/accounts`:

1. Replace the existing text actions with icon-only Edit, Manage, Disable, and Delete controls whose text labels are DuskMoon tooltips and accessible names.
2. Disable an account immediately without deleting its data.
3. Permanently delete an account's local Manifold data through a resumable Oban workflow suitable for a very large mailbox.
4. Keep the account visible as **Deleting...** until the purge completes, then remove the row.

Deletion is local-only. It does not delete mail held by Gmail, Microsoft, IMAP, EAS, or another provider; delete a provider account; revoke provider authorization; or otherwise mutate remote systems.

## Decisions

| Decision | Choice |
| --- | --- |
| Action presentation | Icon-only buttons with DuskMoon tooltips and matching `aria-label` values |
| Disable behavior | Set the account inactive, stop local connector activity, retain local data |
| Delete confirmation | Accessible modal requiring an exact, server-verified full email address |
| Delete execution | Persistent, idempotent, batched Oban purge workflow |
| Workflow ownership | Dedicated account-lifecycle umbrella app coordinating existing bounded contexts |
| Deleting state | Durable purge state plus inactive account; row remains visible until final account deletion |
| Multi-recipient mail | Remove only the target mailbox's copy; preserve every other mailbox's copy |
| Stored payload cleanup | Delete raw mail and blobs only after no remaining local reference exists |
| Failure behavior | Retry transient failures; show **Delete failed** and allow retry after exhaustion/permanent failure |
| Remote systems | Explicitly out of scope; confirmation copy states that remote data is unaffected |
| Edge installations | Out of scope for this local purge; no remote edge deletion protocol is introduced |

## User Experience

### Table actions

Every account row has one compact action group:

| Action | Icon | Tooltip / accessible label | Availability |
| --- | --- | --- | --- |
| Edit | `pencil-outline` | Edit account | Active or disabled |
| Manage | `cog-outline` | Manage account | Active or disabled |
| Disable | `account-off-outline` | Disable account | Active only |
| Delete | `delete-outline` | Delete account | Active or disabled |

Buttons use the established `.settings-icon-button` styling. Delete uses the existing danger treatment. Visible button text is omitted; tooltip text is also the button's `aria-label`.

A disabled account remains in the table. Its receive-method cell shows a **Disabled** state, and its Disable control is unavailable. Edit, Manage, and Delete remain available. Re-enabling an account is not part of this feature.

### Delete confirmation

Delete opens an accessible modal associated with the selected account. The modal:

- names the account and full address;
- states that local methods, credentials, messages, drafts, sent mail, folders, attachments, and stored local objects will be permanently removed;
- states that remote provider mail and accounts will not be deleted;
- requires the user to type the exact full account email address;
- validates the submitted value against a freshly loaded account on the server;
- leaves the destructive submit disabled client-side until the value matches, while treating server validation as authoritative.

A mismatch does not enqueue a job and returns an inline error. A matching submission queues deletion, closes the modal, and flashes **Account deletion queued.** Duplicate submissions reuse the same active purge.

### Deleting and failed states

Once deletion is requested, the account is inactive immediately. The row stays visible, but its action group is replaced by an `aria-live="polite"` **Deleting...** state. No account action is available while the purge is incomplete.

The LiveView polls every five seconds only while at least one displayed account is deleting. It reloads authoritative purge/account state on each tick. When the worker deletes the account row, the next refresh removes the row.

If the purge reaches a durable failed state, the row shows **Delete failed** and exposes a retry Delete action. Retrying resumes the existing purge state rather than starting a second purge.

## State Model

### Account state

`mailboxes.active` remains the routing and write-acceptance flag. A nullable `purge_requested_at` marks an account whose local deletion has started. UI state is derived as follows:

| Account / purge data | UI state |
| --- | --- |
| `active = true`, no purge | Active |
| `active = false`, no purge | Disabled |
| `purge_requested_at` set, purge incomplete | Deleting |
| `purge_requested_at` set, purge failed | Delete failed |
| Account row absent | Removed from table |

### Persistent purge data

The lifecycle app owns persistent purge records that survive account removal:

- `account_purges`: opaque purge ID, target mailbox UUID without a foreign key, stage, status, retry/error metadata, and aggregate counts. It must not retain the account address, display name, credentials, message content, or object keys after completion.
- `account_purge_deliveries`: bounded candidate delivery work with a disposition such as `pending`, `shared_retained`, or `purged`.
- `account_purge_objects`: a durable deletion outbox for raw objects, attachment blobs, spool bundles, and connector activity-log paths.

The purge tables are operational state, not a soft-deleted account. Completion leaves only opaque identifiers, timestamps, stages, and counts needed to audit/retry the workflow.

## Application Ownership

### `manifold_accounts`

- Own disabling and the account's active/purge marker changes.
- Advance the route revision exactly once when an active account becomes inactive for disable or deletion.
- Provide locked, transaction-safe lifecycle state changes.
- Continue to own recipient and sender eligibility.

### `manifold_account_lifecycle`

A dedicated `manifold_account_lifecycle` umbrella app coordinates the purge because deletion crosses Accounts, Connectors, Ingest, Mail, Outbound, Storage, Security, and Oban. It depends on those owning apps; those apps do not depend back on the coordinator.

The coordinator owns:

- purge schemas and queries;
- atomic deletion request/enqueue;
- the unique Oban worker;
- stage transitions and retry classification;
- bounded work discovery;
- orchestration of context-owned cleanup APIs;
- completion/failure status.

### Existing contexts

Each existing context exposes the smallest cleanup or write-fence API required for data it owns. The coordinator does not reach into another context's private schema when that context must cancel runtime work, remove stored objects, or preserve its invariants.

## Request and Write Fence

Requesting deletion is one database transaction:

1. Lock the mailbox row with `FOR UPDATE`.
2. Recompute its full address and compare it with the trimmed confirmation input.
3. Reuse or create the active purge record.
4. Set `active = false` and `purge_requested_at`.
5. Advance the route revision exactly once if the account was active.
6. Insert one unique Oban job for the purge in the same transaction.

The job is unique indefinitely by `purge_id` across incomplete states and runs on a dedicated `account_purge` queue with concurrency `1`.

After the transaction commits, all local entry points that can create account-owned state must reject an inactive/purging account inside their persistence transaction. This includes inbound acceptance, external import, connector setup/enable, draft queueing, and other sender operations. Connector polling must not enqueue new work for the account. These fences prevent stale routes or concurrent work from repopulating a large mailbox during deletion.

Disable uses the same account lock and route-revision behavior without creating purge state. It also disables receive/send methods and cancels pending account sync work so polling does not repeatedly enqueue jobs that can no longer import.

## Purge Workflow

The worker is a resumable stage machine. Each execution processes at most 250 records, persists progress, and snoozes/re-enqueues until the current stage is empty. Large ID lists are stored in purge work tables, never in Oban arguments.

### 1. Discover ownership

Persist candidate identifiers before deleting connector mappings:

- receive and send method IDs;
- connector remote-message IDs and their inbound delivery IDs;
- outbound message IDs;
- inbound delivery IDs reachable through mailbox entries, delivery recipients, external ingress identities, or connector remote mappings;
- raw object, attachment object, spool, and activity-log candidates as they become safe to remove.

### 2. Cancel and drain work

Cancel matching incomplete jobs through Oban APIs and wait until matching executing work has drained:

- connector sync/apply/read-writeback jobs;
- inbound archive, projection, and security jobs;
- outbound submission jobs.

Global polling/reconciliation jobs remain running, but the account write fence prevents them from recreating target state. The cancellation/drain check is repeated before destructive batches to close races.

### 3. Delete connector data

Delete local receive/send methods and their credentials, settings, cursors, remote mappings, events, OAuth transactions, pending jobs, and connector activity logs. No provider revoke or provider-side deletion call is made.

### 4. Delete outbound data

Delete this account's drafts, queued/sent outbound messages, recipients, submissions, events, and provider-event payloads. Cancel/drain submission work first. Local deletion cannot undo a provider submission that already completed remotely.

### 5. Delete the mailbox copy

Delete the target mailbox's entries, delivery-recipient links, external-ingress mappings, alias targets, folders, and threads in bounded batches.

For mail delivered to multiple accounts, these rows represent the target account's mailbox copy. Other mailboxes' entries, folders, threads, and delivery-recipient links are not touched.

### 6. Delete orphaned payloads

For each candidate inbound delivery, lock and test for ownership outside the target mailbox. If another mailbox still references the delivery, retain the inbound delivery, parsed message, security data, raw object, spool data, and attachment blobs; mark the candidate `shared_retained`.

When no mailbox ownership remains:

1. capture raw, spool, and attachment object identifiers in the durable object outbox;
2. remove restrictive cloud/connector mappings;
3. delete the inbound delivery and its cascading parsed/security/event rows;
4. delete external objects only after the database transaction commits.

Raw objects and content-addressed attachment blobs are removed only when no remaining database row references the same object key. Missing files are treated as already deleted so retries are idempotent.

### 7. Finalize

Repeat ownership discovery and job draining, then verify that no restrictive account-owned rows remain. Delete the mailbox row, mark the purge completed with counts, and remove sensitive transient purge-work data. The account disappears from the table on the next LiveView refresh.

## Error Handling and Recovery

| Case | Behavior |
| --- | --- |
| Confirmation mismatch | Inline error; no state change or job |
| Duplicate request | Return existing active purge; no duplicate job |
| Database/storage transient failure | Preserve stage/work rows and retry with backoff |
| Object already missing | Treat as successful idempotent cleanup |
| Worker crashes between DB and object cleanup | Durable object outbox resumes cleanup |
| Matching job still executing | Snooze purge stage until drained |
| New write races deletion request | Account row lock and in-transaction active check reject it |
| Attempts exhausted/permanent local failure | Persist failed state and safe error summary; account remains inactive |
| Retry after failure | Resume existing purge from durable stage/work state |
| Shared message/blob | Preserve while any other mailbox/database reference remains |

No failure path reactivates an account automatically.

## Testing

### Accounts

- Disable sets `active = false`, preserves data, and removes the account from active-recipient/sender lists.
- Disable advances the route revision once; repeated disable is idempotent.
- Deletion request verifies the current full address under lock, marks inactive/deleting, advances revision once, and atomically inserts one unique job.
- Inbound, external import, connector, and outbound persistence reject disabled/purging accounts at the transaction boundary.

### Lifecycle worker

- Duplicate requests and duplicate worker execution are idempotent.
- Work is processed in bounded batches and resumes from persisted stages.
- Matching queued/executing jobs are cancelled/drained before row deletion.
- Receive/send methods, credentials, connector data, outbound data, mailbox projections, and local storage are removed.
- Another mailbox's copy of a multi-recipient message remains readable and unchanged.
- Shared raw objects/blobs remain; orphaned objects are removed.
- Crash after row deletion but before object deletion resumes from the outbox.
- Missing objects do not fail a retry.
- Finalization deletes the account and retains only non-sensitive purge audit data.

### LiveView

- Edit, Manage, Disable, and Delete are icon-only controls with tooltip and `aria-label` text.
- Disable updates the row to **Disabled** and makes Disable unavailable.
- Delete opens the accessible confirmation modal with the local-only/remote-unchanged warning.
- Wrong email queues no job and shows an error.
- Correct email queues one purge and changes the row to **Deleting...**.
- Actions are unavailable while deleting.
- Conditional polling removes the row after completion.
- Failed state is visible and retry resumes the same purge.

## Expected File Map

| Area | Expected change |
| --- | --- |
| `apps/manifold_data/priv/repo/migrations` | Account purge marker and lifecycle work tables |
| `apps/manifold_accounts` | Disable and locked lifecycle state APIs; route revision behavior/tests |
| New lifecycle umbrella app | Purge schemas, coordinator, Oban worker, stage logic, and tests |
| `apps/manifold_connectors` | Account-wide quiesce/cleanup and activity-log deletion APIs/tests |
| `apps/manifold_ingest` | In-transaction account write fence and owned-delivery cleanup APIs/tests |
| `apps/manifold_mail` | Mailbox-copy deletion and shared-payload ownership checks with tests |
| `apps/manifold_outbound` | Write fence, job cancellation, and account cleanup APIs/tests |
| `apps/manifold_storage` | Idempotent raw/blob/spool deletion support/tests |
| `config/config.exs` | `account_purge` queue with concurrency `1` |
| `apps/manifold_data/lib/manifold/data/oban_jobs.ex` | Queue visibility in Operations UI |
| `apps/manifold_web/lib/manifold_web/live/account_live/index.ex` | Icon actions, confirmation modal, lifecycle handlers, and conditional polling |
| `apps/manifold_web/test/manifold_web/account_live_test.exs` | Action, confirmation, deleting, failed, and completion coverage |
| `.agents/skills/develop/references/account-actions.md` | Feature ownership, implementation notes, and follow-ups after implementation |

## Out of Scope

- Re-enabling a disabled account.
- Deleting or modifying provider-held mail or provider accounts.
- Revoking OAuth grants or other provider authorization.
- Undoing mail already submitted to a remote provider.
- Purging historical records from a separately deployed edge instance.
- Changing the physical mail projection solely to duplicate a shared payload per recipient; the required behavior is that each mailbox's visible copy and ownership remain independent.

## Success Criteria

- The account table has compact, accessible icon actions with tooltip labels.
- Disable takes effect immediately, stops local account activity, and retains local data.
- Delete cannot start without exact full-address confirmation and a clear local-only warning.
- Large local mailboxes delete asynchronously in bounded, retry-safe work.
- A deleting account cannot receive, import, sync, or queue new local data.
- Other accounts' copies of multi-recipient mail remain intact.
- The row shows **Deleting...** until local deletion completes and then disappears.
- Failures remain observable and retryable without reactivating the account or duplicating purge work.
