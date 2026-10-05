# Account Disable and Asynchronous Local Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add accessible icon-only account actions, immediate local disablement, and exact-address-confirmed asynchronous deletion that removes only the selected account's local data while preserving every other mailbox's copy of shared mail.

**Architecture:** Add a dedicated `manifold_account_lifecycle` umbrella app that stores purge progress and coordinates narrow cleanup APIs owned by Accounts, Connectors, Ingest, Mail, Outbound, and Storage. The delete request deactivates the mailbox and inserts one unique Oban job in one database transaction; a bounded, resumable stage machine drains jobs, removes account-owned rows, deletes only unreferenced objects, then deletes the mailbox. Account LiveView derives Disabled, Deleting, and Delete failed states from durable data and polls only while deletion is running.

**Tech Stack:** Elixir 1.18, Ecto/PostgreSQL, Oban 2.23, Phoenix LiveView 1.2, Phoenix DuskMoon 9.9, ExUnit, local raw/blob/spool storage.

---

## Global constraints

- Implement the approved design in `docs/superpowers/specs/2026-08-10-account-disable-async-delete-design.md` without adding remote provider deletion, OAuth revocation, re-enable behavior, or an edge purge protocol.
- Treat `mailboxes.active` as the routing/write fence and `mailboxes.purge_requested_at` as the durable deletion marker.
- Process no more than 250 database work items in one worker execution. Never place delivery IDs, message IDs, object keys, or addresses in Oban arguments.
- The only Oban argument is `%{"purge_id" => purge_id}`. Keep one incomplete job per purge.
- Recompute the full address under the mailbox row lock. Client-side matching only controls button availability; server-side matching is authoritative.
- Remove the target mailbox's `mailbox_entries`, `delivery_recipients`, and account-scoped connector mappings. Do not delete an `inbound_delivery`, parsed `message`, security rows, raw object, spool bundle, or attachment blob while another mailbox or connector mapping still references that delivery/object.
- Missing local files are successful idempotent deletion. Permanent path/key validation failures remain failures.
- Run commands from `/home/gao/Workspace/gsmlg-opt/manifold/.trees/account-disable-async-delete`.
- Before Task 1, populate the worktree's ignored dependency directory with `devenv shell -- mix deps.get`.
- Until the worktree can own a separate PostgreSQL socket, use the already-running project test database:

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_account_lifecycle/test apps/manifold_accounts/test'
```

- After every task, run `mix format` on only the task's changed Elixir/HEEx files before committing.

## Public contracts

| Context | Contract introduced or changed |
| --- | --- |
| `Manifold.Accounts` | `disable_account/1`, transaction-safe `disable_account/2`, `active_account_for_update/2`, `begin_purge/4`, `delete_purging_account/2`, and active checks that include `purge_requested_at` |
| `Manifold.AccountLifecycle` | `disable_account/1`, `request_deletion/2`, `retry_deletion/1`, `states_by_mailbox/1` |
| `Manifold.Connectors` | account quiesce, job drain, delivery discovery/ownership, bounded local cleanup |
| `Manifold.Connectors.ActivityLog` | validated, idempotent `delete_account/1` |
| `Manifold.Ingest` | in-transaction active fences, delivery discovery/ownership, bounded mailbox-link cleanup, orphan delivery deletion |
| `Manifold.Mail` | delivery discovery/ownership, bounded mailbox-entry cleanup, attachment candidate/reference queries |
| `Manifold.Outbound` | in-transaction sender fence, job drain, bounded account cleanup |
| `Manifold.Storage` | idempotent raw/blob/spool deletion at public boundaries |
| `Manifold.AccountLifecycle.Jobs.PurgeAccount` | unique `account_purge` worker and persisted stage machine |

## File map

| Path | Change |
| --- | --- |
| `apps/manifold_data/priv/repo/migrations/20260810000100_create_account_purge_lifecycle.exs` | Add `purge_requested_at` and purge/work/outbox tables |
| `apps/manifold_account_lifecycle/**` | New app, schemas, coordinator, worker, stage engine, tests |
| `apps/manifold_accounts/lib/manifold/accounts.ex` | Locked deactivate/delete state transitions and active checks |
| `apps/manifold_accounts/lib/manifold/accounts/schema/account.ex` | Persist `purge_requested_at` |
| `apps/manifold_accounts/test/manifold/accounts_test.exs` | Disable/purge state and route revision tests |
| `apps/manifold_connectors/lib/manifold/connectors.ex` | Quiesce, fencing, job drain, discovery, and cleanup APIs |
| `apps/manifold_connectors/lib/manifold/connectors/activity_log.ex` | Delete one validated account log directory |
| `apps/manifold_connectors/test/manifold/connectors_test.exs` | Connector lifecycle tests |
| `apps/manifold_connectors/test/manifold/connectors/activity_log_test.exs` | Idempotent activity-log deletion tests |
| `apps/manifold_ingest/lib/manifold/ingest.ex` | Transactional active fences and purge APIs |
| `apps/manifold_ingest/test/manifold/ingest_test.exs` | Stale-route/external-import and ownership tests |
| `apps/manifold_mail/lib/manifold/mail.ex` | Mailbox-copy and shared-payload query APIs |
| `apps/manifold_mail/test/manifold/mail_test.exs` | Shared-copy and blob-reference tests |
| `apps/manifold_outbound/lib/manifold/outbound.ex` | Queue fence, job drain, and cleanup APIs |
| `apps/manifold_outbound/test/manifold/outbound_test.exs` | Inactive queue and cleanup tests |
| `apps/manifold_storage/lib/manifold/storage/{raw_store/local.ex,blob_store/local.ex,spool.ex}` | Missing-object success behavior |
| `apps/manifold_storage/test/manifold/storage_test.exs` | Idempotent delete tests |
| `apps/manifold_web/lib/manifold_web/live/account_live/index.ex` | Icon actions, confirmation dialog, state refresh, conditional polling |
| `apps/manifold_web/assets/css/app.css` | Account-state and delete-dialog styling using existing tokens |
| `apps/manifold_web/test/manifold_web/account_live_test.exs` | Accessible actions and lifecycle behavior |
| `apps/manifold_web/mix.exs`, `mix.exs`, `config/config.exs` | App dependency/release and Oban queue wiring |
| `apps/manifold_data/lib/manifold/data/oban_jobs.ex` | Operations queue visibility |
| `.agents/skills/develop/references/account-actions.md` | Feature ownership and operational notes |

### Task 1: Add lifecycle persistence and the umbrella app

**Files:**
- Create: `apps/manifold_account_lifecycle/mix.exs`
- Create: `apps/manifold_account_lifecycle/lib/manifold/account_lifecycle/application.ex`
- Create: `apps/manifold_account_lifecycle/lib/manifold/account_lifecycle/schema.ex`
- Create: `apps/manifold_account_lifecycle/lib/manifold/account_lifecycle/schema/account_purge.ex`
- Create: `apps/manifold_account_lifecycle/lib/manifold/account_lifecycle/schema/purge_delivery.ex`
- Create: `apps/manifold_account_lifecycle/lib/manifold/account_lifecycle/schema/purge_object.ex`
- Create: `apps/manifold_account_lifecycle/test/test_helper.exs`
- Create: `apps/manifold_account_lifecycle/test/manifold/account_lifecycle/schema_test.exs`
- Create: `apps/manifold_data/priv/repo/migrations/20260810000100_create_account_purge_lifecycle.exs`
- Modify: `config/config.exs`
- Modify: `apps/manifold_data/lib/manifold/data/oban_jobs.ex`
- Modify: `mix.exs`

- [ ] **Step 1: Scaffold the app so its tests can compile**

Use `app: :manifold_account_lifecycle`, the existing `0.3.0` umbrella version, and these in-umbrella dependencies: `manifold_accounts`, `manifold_connectors`, `manifold_ingest`, `manifold_mail`, `manifold_outbound`, `manifold_security`, `manifold_storage`, `manifold_data`, plus `{:oban, "~> 2.23"}`. The application starts no children yet.

The test helper must match other database apps:

```elixir
ExUnit.start()
Code.require_file("../../../test/support/repo_setup.exs", __DIR__)
Code.require_file("../../../test/support/data_case.exs", __DIR__)
```

- [ ] **Step 2: Write failing schema/config tests**

Create `schema_test.exs` with `use Manifold.DataCase, async: true` and assertions that:

```elixir
test "purge requires an opaque mailbox id and valid lifecycle state" do
  changeset = AccountPurge.changeset(%AccountPurge{}, %{mailbox_id: Ecto.UUID.generate()})

  assert changeset.valid?
  assert Ecto.Changeset.get_field(changeset, :status) == "requested"
  assert Ecto.Changeset.get_field(changeset, :stage) == "discover"
  refute Map.has_key?(changeset.changes, :address)
end

test "account purge queue is configured and visible" do
  assert "account_purge" in Manifold.Data.ObanJobs.queues()
end
```

The test environment intentionally sets Oban queues to `false`; the assertion therefore exercises the updated `@default_queues`. Verify the configured concurrency from the `config/config.exs` diff and later strict compile rather than overriding the test environment.

- [ ] **Step 3: Run the new app test and verify RED**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_account_lifecycle/test'
```

Expected: compile failures for the missing schema modules and assertion failures for the absent queue.

- [ ] **Step 4: Add the migration**

The migration must:

```elixir
alter table(:mailboxes) do
  add(:purge_requested_at, :utc_datetime_usec)
end

create(index(:mailboxes, [:purge_requested_at], where: "purge_requested_at IS NOT NULL"))
```

Create `account_purges` with a binary UUID primary key, plain `mailbox_id :binary_id` with no foreign key, `status` default `requested`, `stage` default `discover`, `progress :map` default `%{}`, nullable safe error class/code/message fields, integer counters defaulting to zero, `started_at`, `completed_at`, and microsecond timestamps. Add a unique index on `mailbox_id` and check constraints for:

```text
status IN ('requested', 'running', 'failed', 'completed')
stage IN ('discover', 'drain', 'connectors', 'outbound', 'mailbox_copy', 'orphan_payloads', 'objects', 'finalize', 'completed')
all counters >= 0
```

Create `account_purge_deliveries` with `purge_id` cascading to `account_purges`, a plain `inbound_delivery_id :binary_id` without an FK, `disposition` default `pending`, timestamps, a unique index on `[purge_id, inbound_delivery_id]`, and a disposition constraint for `pending`, `shared_retained`, `purged`.

Create `account_purge_objects` with `purge_id`, `kind`, `object_key`, `status` default `pending`, `attempts` default `0`, `last_error`, timestamps, a unique index on `[purge_id, kind, object_key]`, and constraints for kinds `raw`, `blob`, `spool`, `activity_log`, statuses `pending`, `completed`, and nonnegative attempts.

- [ ] **Step 5: Implement schemas without PII fields**

Use a shared binary-id schema macro matching existing app schemas. `AccountPurge.changeset/2` casts only the migration fields above; do not add address, name, credential, message-content, or provider-token fields. `PurgeDelivery` and `PurgeObject` belong to `AccountPurge` and deliberately do not declare foreign-key associations to deliveries or storage objects.

- [ ] **Step 6: Wire the app and queue**

Add `account_purge: 1` to `config :manifold_data, Oban`; add `account_purge` to `Manifold.Data.ObanJobs.@default_queues`; add `manifold_account_lifecycle: :permanent` after Connectors and before Web in only the `manifold` release. Do not add it to `manifold_edge`.

- [ ] **Step 7: Migrate test DB and verify GREEN**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; export MIX_ENV=test; exec mix ecto.migrate'
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_account_lifecycle/test apps/manifold_data/test'
```

Expected: both app suites pass.

- [ ] **Step 8: Commit**

```bash
git add apps/manifold_account_lifecycle apps/manifold_data/priv/repo/migrations/20260810000100_create_account_purge_lifecycle.exs config/config.exs apps/manifold_data/lib/manifold/data/oban_jobs.ex mix.exs
git commit -m "feat(account-lifecycle): add durable purge state"
```

### Task 2: Implement locked account lifecycle state transitions

**Files:**
- Modify: `apps/manifold_accounts/lib/manifold/accounts/schema/account.ex`
- Modify: `apps/manifold_accounts/lib/manifold/accounts.ex`
- Modify: `apps/manifold_accounts/test/manifold/accounts_test.exs`

- [ ] **Step 1: Write failing disable and purge-transition tests**

Add tests covering:

```elixir
test "disable_account deactivates once and advances route revision once" do
  {:ok, account} = Accounts.create_account(%{address: "disable@example.test"})
  before_revision = route_revision()

  assert {:ok, disabled} = Accounts.disable_account(account.id)
  refute disabled.active
  assert is_nil(disabled.purge_requested_at)
  assert route_revision() == before_revision + 1

  assert {:ok, _disabled} = Accounts.disable_account(account.id)
  assert route_revision() == before_revision + 1
end

test "begin_purge verifies the current address under lock" do
  {:ok, account} = Accounts.create_account(%{address: "purge@example.test"})
  now = DateTime.utc_now()

  assert {:error, :confirmation_mismatch} =
           Repo.transaction(fn ->
             case Accounts.begin_purge(Repo, account.id, "wrong@example.test", now) do
               {:ok, value} -> value
               {:error, reason} -> Repo.rollback(reason)
             end
           end)

  assert {:ok, purging} =
           Repo.transaction(fn ->
             {:ok, purging} = Accounts.begin_purge(Repo, account.id, "purge@example.test", now)
             purging
           end)

  refute purging.active
  assert purging.purge_requested_at == now
end
```

Also assert `list_active_accounts/0`, `active_account_domain_id/1`, and `get_sender_identity/1` reject disabled and purging accounts.

- [ ] **Step 2: Run the Accounts tests and verify RED**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_accounts/test/manifold/accounts_test.exs'
```

Expected: missing field/functions.

- [ ] **Step 3: Add the schema field and lifecycle changeset**

Add `field(:purge_requested_at, :utc_datetime_usec)` and cast it. Add a private lifecycle changeset that only changes `active` and `purge_requested_at`; do not make deletion state editable through the normal account form.

- [ ] **Step 4: Implement locked transitions**

Add these contracts:

```elixir
@spec disable_account(Ecto.UUID.t()) :: {:ok, Account.t()} | {:error, Error.t() | term()}
@spec disable_account(module(), Ecto.UUID.t()) ::
        {:ok, Account.t()} | {:error, Error.t() | Ecto.Changeset.t()}
@spec active_account_for_update(module(), Ecto.UUID.t()) ::
        {:ok, Account.t()} | {:error, Error.t()}
@spec begin_purge(module(), Ecto.UUID.t(), String.t(), DateTime.t()) ::
        {:ok, Account.t()} | {:error, :confirmation_mismatch | Error.t() | Ecto.Changeset.t()}
@spec delete_purging_account(module(), Ecto.UUID.t()) ::
        {:ok, Account.t()} | {:error, Error.t() | Ecto.Changeset.t()}
```

The public `disable_account/1` wraps transaction-safe `disable_account/2`. The transaction-safe functions load the account joined to its domain with `lock("FOR UPDATE")`. `active_account_for_update/2` additionally requires `active = true` and `purge_requested_at IS NULL`. `begin_purge/4` compares `String.trim(confirmation)` with `local_part <> "@" <> normalized_domain`, changes `active` to false, and sets `purge_requested_at` only when nil. `delete_purging_account/2` refuses an account without `purge_requested_at`.

Extract the existing route-revision update so the transition advances it only when the locked account was active. A repeated disable or delete request must not advance it again.

- [ ] **Step 5: Tighten active predicates**

Require `is_nil(account.purge_requested_at)` alongside `account.active` in active listing, sender identity, domain lookup, recipient snapshot, and route-resolution queries. This is a defense-in-depth predicate even though purge requests also set `active = false`.

- [ ] **Step 6: Verify GREEN**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_accounts/test'
```

- [ ] **Step 7: Commit**

```bash
git add apps/manifold_accounts
git commit -m "feat(accounts): add locked lifecycle transitions"
```

### Task 3: Quiesce and clean connector-owned local state

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/activity_log.ex`
- Modify: `apps/manifold_connectors/test/manifold/connectors_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/activity_log_test.exs`

- [ ] **Step 1: Write failing connector lifecycle tests**

Cover these cases:

1. `quiesce_account/2` sets every receive method's `enabled` and `sync_enabled` false and every send method's `enabled` false in the caller's transaction, without deleting credentials.
2. `enqueue_due_syncs/0`, OAuth completion, receive/send method creation and enable paths reject an inactive or purging mailbox.
3. `cancel_account_jobs/2` cancels at most the passed limit of `SyncAccount` jobs by receive method ID and `ApplyRemoteState`/`PushRemoteRead` jobs by remote-message ID, and returns `{:snooze, seconds}` while matching jobs are still executing.
4. `list_account_delivery_ids/3` returns stable UUID-ordered pages through the account's remote messages.
5. `purge_account_batch/3` removes at most the passed limit, removes remote mappings before receive methods, deletes send methods/OAuth transactions locally, and never invokes a provider revoke/delete adapter callback.
6. `ActivityLog.delete_account/1` deletes exactly the validated UUID directory and returns `:ok` on a second call.

Use `Oban.Testing` helpers and assert job state rather than deleting `oban_jobs` rows directly.

- [ ] **Step 2: Run connector tests and verify RED**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_connectors/test'
```

- [ ] **Step 3: Add the in-transaction mailbox fence**

Create a private helper used inside connector persistence transactions:

```elixir
defp ensure_active_mailbox(repo, mailbox_id) do
  case Accounts.active_account_for_update(repo, mailbox_id) do
    {:ok, account} -> {:ok, account}
    {:error, _} -> {:error, database_error(:mailbox_not_active)}
  end
end
```

Call it before persisting OAuth completion, placeholder/IMAP/EAS receive methods, SMTP send methods, and enable/update operations. Join `mailboxes` in `enqueue_due_syncs/0` and require `mailboxes.active` plus `purge_requested_at IS NULL`.

- [ ] **Step 4: Add quiesce and job-drain APIs**

`quiesce_account(repo, mailbox_id)` uses `update_all` within the supplied transaction and has no remote side effects. `cancel_account_jobs(mailbox_id, limit)` resolves account-scoped method/message IDs, builds explicit worker-and-args queries limited to at most `limit` Oban rows, calls `Oban.cancel_all_jobs/1`, then checks for remaining `executing` matches. Return `%{cancelled: count, done?: boolean()}` only after the selected jobs have drained; return `{:snooze, 5}` otherwise.

- [ ] **Step 5: Add bounded discovery and cleanup**

Use UUID ordering and `id > ^after_id` for `list_account_delivery_ids/3`. Return `%{ids: ids, next: List.last(ids), done?: length(ids) < limit}`.

`purge_account_batch(repo, mailbox_id, limit)` must perform one bounded class of deletion per call in this order: remote messages, receive methods, send methods, OAuth transactions. Return `%{deleted: count, done?: boolean(), activity_log_ids: [method_id]}`. Child settings, credentials, cursors, and connector events may cascade from their parent. Accepting the caller's repo allows the lifecycle coordinator to persist `activity_log_ids` to its object outbox in the same transaction before parent deletion. Add `account_data_remaining?/1` for final verification.

- [ ] **Step 6: Add safe activity-log deletion**

After `validate_account_id/1`, delete only `Path.join(root_dir(), account_id)` with `File.rm_rf/1`. Accept `{:ok, _}` and `{:error, :enoent}` as `:ok`; return other errors. Never accept path separators or relative components.

- [ ] **Step 7: Verify GREEN and commit**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_connectors/test'
git add apps/manifold_connectors
git commit -m "feat(connectors): support account lifecycle cleanup"
```

### Task 4: Fence ingest writes and expose delivery cleanup

**Files:**
- Modify: `apps/manifold_ingest/lib/manifold/ingest.ex`
- Modify: `apps/manifold_ingest/test/manifold/ingest_test.exs`

- [ ] **Step 1: Write failing stale-write and cleanup tests**

Add tests that freeze a valid route, disable the account, then prove both `accept/3` and `accept_edge/5` return a permanent `:mailbox_not_active` error without inserting a delivery. Add a narrowly scoped `before_persist` test callback to the existing ingest option/fault boundary; use it to disable the mailbox after preliminary external-source validation but before the persistence transaction, then prove no `external_ingress_identity` is inserted.

Add API tests for:

```elixir
assert %{ids: [delivery_id], done?: true} =
         Ingest.list_account_delivery_ids(mailbox.id, nil, 250)

assert Ingest.delivery_owned?(delivery_id)
assert %{deleted: 1, done?: true} = Ingest.delete_mailbox_links_batch(mailbox.id, 250)
refute Ingest.delivery_owned?(delivery_id)
```

Also test `delete_orphan_delivery/2` deletes the cloud identity and delivery, returns raw/spool candidates, and fails with `:delivery_still_owned` when any mailbox link remains.

Insert ArchiveRawEmail, ProjectInboundMail, and EvaluateInboundSecurity jobs and test `cancel_delivery_jobs/2` cancels no more than the passed limit of incomplete jobs for the supplied delivery IDs and returns `{:snooze, 5}` while a matching job still executes.

- [ ] **Step 2: Run Ingest tests and verify RED**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_ingest/test/manifold/ingest_test.exs'
```

- [ ] **Step 3: Put account validation inside persistence transactions**

In `persist_acceptance/3`, `persist_edge_acceptance/6`, and `persist_external_acceptance/4`, invoke the optional `before_persist` test callback immediately before `Repo.transaction/1`, then add a first `Multi.run` that locks every target mailbox through the Accounts transaction-safe active API. Reject the complete transaction if any target is inactive or purging. Preserve the current outer validation for fast feedback, but do not rely on it for correctness. Keep the callback undocumented and use it only in the race regression test, following the existing `fail_at` option precedent.

- [ ] **Step 4: Implement delivery APIs**

`list_account_delivery_ids/3` unions delivery recipients and external ingress identities for the mailbox, deduplicates, sorts by UUID, and pages after the cursor. `delivery_owned?/1` checks both tables.

`delete_mailbox_links_batch/2` deletes at most `limit` rows from one table per call, external ingress identities first and delivery recipients second, returning a deterministic `done?` result.

`delete_orphan_delivery(repo, delivery_id)` must lock the delivery, recheck delivery recipients and external ingress identities, remove a matching cloud ingress identity, delete the delivery, and return:

```elixir
%{
  raw_object_key: delivery.raw_object_key,
  spool_bundle_path: delivery.spool_bundle_path
}
```

Add `raw_object_referenced?/1` and `spool_path_referenced?/1` for the object stage.

Add `cancel_delivery_jobs/2` using exact worker and `inbound_delivery_id` argument predicates plus a limited Oban ID subquery, and add `account_data_remaining?/1` for final verification.

- [ ] **Step 5: Verify GREEN and commit**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_ingest/test'
git add apps/manifold_ingest
git commit -m "feat(ingest): fence and clean purging mailboxes"
```

### Task 5: Fence outbound writes and expose bounded cleanup

**Files:**
- Modify: `apps/manifold_outbound/lib/manifold/outbound.ex`
- Modify: `apps/manifold_outbound/test/manifold/outbound_test.exs`

- [ ] **Step 1: Write failing queue-race and cleanup tests**

Create a draft while active, disable the mailbox, then assert `queue_draft/3` returns the existing permanent `:sender_not_active` error and inserts neither a provider submission nor `SubmitOutbound` job. Repeat for create/update paths that persist sender-owned data.

Add tests that repeated `cancel_account_jobs/2` calls cancel matching incomplete submission jobs in batches no larger than the passed limit and wait for executing jobs, and that `purge_account_batch/2`:

- deletes no more than the requested limit;
- deletes `provider_events` while their `outbound_message_id` is still present;
- then deletes the message so recipients, submissions, and outbound events cascade;
- leaves another mailbox's outbound rows unchanged.

- [ ] **Step 2: Run Outbound tests and verify RED**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_outbound/test/manifold/outbound_test.exs'
```

- [ ] **Step 3: Add the transaction-local sender fence**

In `queue_draft/3`, lock and verify the mailbox through Accounts in the same `Multi` before locking/updating the draft. Apply the same in-transaction fence to create/update persistence paths even if they already call `get_sender_identity/1` before the transaction.

- [ ] **Step 4: Add job drain and cleanup**

`cancel_account_jobs(mailbox_id, limit)` queries no more than `limit` `SubmitOutbound` jobs whose `outbound_message_id` is in the target mailbox's message IDs, calls `Oban.cancel_all_jobs/1`, and returns `{:snooze, 5}` while matches execute. Otherwise return `%{cancelled: count, done?: boolean()}`.

`purge_account_batch/2` selects at most `limit` outbound IDs with `FOR UPDATE SKIP LOCKED`, deletes associated `provider_events` explicitly, then deletes messages. Return `%{deleted: count, done?: boolean()}`. Add `account_data_remaining?/1` for final verification.

- [ ] **Step 5: Verify GREEN and commit**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_outbound/test'
git add apps/manifold_outbound
git commit -m "feat(outbound): fence and purge account mail"
```

### Task 6: Preserve shared mail while deleting one mailbox copy

**Files:**
- Modify: `apps/manifold_mail/lib/manifold/mail.ex`
- Modify: `apps/manifold_mail/test/manifold/mail_test.exs`

- [ ] **Step 1: Write the multi-recipient regression first**

Create one inbound delivery addressed to two local accounts and project it so both have mailbox entries. Assert:

```elixir
assert %{ids: [delivery_id]} = Mail.list_account_delivery_ids(first.id, nil, 250)
assert Mail.delivery_owned?(delivery_id)

assert %{deleted: 1, done?: true} = Mail.delete_mailbox_entries_batch(first.id, 250)

refute Repo.exists?(from e in MailboxEntry, where: e.mailbox_id == ^first.id)
assert Repo.exists?(from e in MailboxEntry, where: e.mailbox_id == ^second.id)
assert Repo.get!(Message, message.id)
assert Mail.delivery_owned?(delivery_id)
```

Add a second test where two attachment rows use one content-addressed `object_key`; deleting the first delivery must leave `blob_referenced?(object_key)` true until the second attachment is gone.

- [ ] **Step 2: Run Mail tests and verify RED**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_mail/test/manifold/mail_test.exs'
```

- [ ] **Step 3: Implement bounded mailbox-copy APIs**

`list_account_delivery_ids/3` pages the mailbox's entry delivery IDs. `delete_mailbox_entries_batch/2` deletes at most `limit` entries with a UUID-ordered subquery. Do not delete `messages`, `attachments`, folders, or threads here; folders/threads cascade only when the mailbox is finalized.

Add:

```elixir
@spec delivery_owned?(Ecto.UUID.t()) :: boolean()
@spec attachment_object_keys(module(), Ecto.UUID.t()) :: [String.t()]
@spec blob_referenced?(String.t()) :: boolean()
```

`attachment_object_keys/2` reads keys before the inbound delivery cascades its message and attachments. `blob_referenced?/1` checks live attachment rows immediately before external deletion.

Add `account_data_remaining?/1` so finalization can prove no mailbox entries remain before deleting the account.

- [ ] **Step 4: Verify GREEN and commit**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_mail/test'
git add apps/manifold_mail
git commit -m "feat(mail): isolate mailbox copy cleanup"
```

### Task 7: Make local object deletion retry-safe

**Files:**
- Modify: `apps/manifold_storage/lib/manifold/storage/raw_store/local.ex`
- Modify: `apps/manifold_storage/lib/manifold/storage/blob_store/local.ex`
- Modify: `apps/manifold_storage/lib/manifold/storage/spool.ex`
- Modify: `apps/manifold_storage/test/manifold/storage_test.exs`

- [ ] **Step 1: Write failing idempotence tests**

For each public delete path, create a valid object/bundle, delete it, delete it again, and assert `:ok` both times. Keep existing assertions for invalid raw keys, invalid blob digests, and unsafe spool paths.

- [ ] **Step 2: Run Storage tests and verify RED**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_storage/test/manifold/storage_test.exs'
```

- [ ] **Step 3: Normalize only missing-object errors**

Change each adapter at its validated delete boundary:

```elixir
case File.rm(path) do
  :ok -> :ok
  {:error, :enoent} -> :ok
  {:error, reason} -> {:error, reason}
end
```

For blob deletion, sync the parent directory after a real removal and skip syncing when the file was already absent. Preserve every existing key/path validation check.

- [ ] **Step 4: Verify GREEN and commit**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_storage/test'
git add apps/manifold_storage
git commit -m "fix(storage): make object deletion idempotent"
```

### Task 8: Implement atomic lifecycle requests and status queries

**Files:**
- Create: `apps/manifold_account_lifecycle/lib/manifold/account_lifecycle.ex`
- Create: `apps/manifold_account_lifecycle/lib/manifold/account_lifecycle/jobs/purge_account.ex`
- Create: `apps/manifold_account_lifecycle/lib/manifold/account_lifecycle/purge.ex`
- Create: `apps/manifold_account_lifecycle/test/manifold/account_lifecycle_test.exs`
- Modify: `apps/manifold_web/mix.exs`

- [ ] **Step 1: Write failing request, duplicate, retry, and disable tests**

Use `Oban.Testing` and assert:

```elixir
assert {:error, :confirmation_mismatch} =
         AccountLifecycle.request_deletion(account.id, "wrong@example.test")
refute Accounts.get_account!(account.id).purge_requested_at
refute_enqueued(worker: PurgeAccount)

assert {:ok, purge} =
         AccountLifecycle.request_deletion(account.id, "delete@example.test")
assert_enqueued(worker: PurgeAccount, args: %{"purge_id" => purge.id})

assert {:ok, same_purge} =
         AccountLifecycle.request_deletion(account.id, "delete@example.test")
assert same_purge.id == purge.id
assert 1 == incomplete_purge_job_count(purge.id)
```

Verify the account flag, purge row, connector quiesce, route revision, and job insertion all roll back when `request_deletion/3` receives the test option `fail_at: :before_job_insert`. The public `request_deletion/2` delegates to `/3` with an empty option list. Verify `disable_account/1` quiesces connectors but creates neither purge nor job. Set a purge to `failed`, call `retry_deletion/1`, and assert it resets to `requested` without changing its ID.

- [ ] **Step 2: Run lifecycle tests and verify RED**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_account_lifecycle/test/manifold/account_lifecycle_test.exs'
```

- [ ] **Step 3: Define the unique worker**

```elixir
defmodule Manifold.AccountLifecycle.Jobs.PurgeAccount do
  use Oban.Worker,
    queue: :account_purge,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:purge_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"purge_id" => purge_id}} = job) do
    Manifold.AccountLifecycle.Purge.run(purge_id, job)
  end
end
```

Start `Purge.run/2` with the durable terminal behavior: load the purge by ID, return `:ok` for `completed`, and return `{:snooze, 1}` for other persisted states. Task 9 expands this same function into the complete stage dispatcher, so every intermediate commit compiles and duplicate execution of a completed purge is already safe.

- [ ] **Step 4: Build request and disable transactions**

`request_deletion/2` uses `Ecto.Multi` in this order: `Accounts.begin_purge/4`, insert-or-load `account_purges` by `mailbox_id`, `Connectors.quiesce_account/2`, insert `PurgeAccount.new(%{"purge_id" => id})`. Pass the same `DateTime.utc_now()` to state changes. Map the Accounts rollback reason `:confirmation_mismatch` directly to the public result.

`disable_account/1` calls transaction-safe `Accounts.disable_account(repo, mailbox_id)` and connector quiesce in one transaction, without a purge record or job.

`retry_deletion/1` locks the failed purge, verifies the mailbox is still marked purging, sets status to `requested` while preserving stage/progress/work rows, clears safe error fields, and inserts a new unique worker job.

- [ ] **Step 5: Add batched status lookup**

`states_by_mailbox(ids)` performs one query and returns:

```elixir
%{
  mailbox_id => %{
    purge_id: purge.id,
    status: purge.status,
    stage: purge.stage,
    error_message: purge.error_message
  }
}
```

Return `%{}` for an empty ID list. Do not expose progress maps or object keys to Web.

- [ ] **Step 6: Add the Web dependency, verify, and commit**

Add `{:manifold_account_lifecycle, in_umbrella: true}` to `apps/manifold_web/mix.exs`.

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_account_lifecycle/test'
git add apps/manifold_account_lifecycle apps/manifold_web/mix.exs
git commit -m "feat(account-lifecycle): enqueue atomic account purges"
```

### Task 9: Implement the bounded purge stage machine

**Files:**
- Modify: `apps/manifold_account_lifecycle/lib/manifold/account_lifecycle/purge.ex`
- Create: `apps/manifold_account_lifecycle/test/manifold/account_lifecycle/purge_test.exs`
- Modify: `apps/manifold_account_lifecycle/lib/manifold/account_lifecycle/jobs/purge_account.ex`

- [ ] **Step 1: Write the end-to-end shared-message purge test**

Create two accounts sharing one inbound delivery, plus one target-only delivery, connector methods/remotes, an outbound draft/submission/event, raw objects, a shared attachment blob, and activity logs. Request deletion and repeatedly call `perform_job(PurgeAccount, %{"purge_id" => purge.id})` until the purge completes.

Assert:

- the target mailbox is absent and the other mailbox remains;
- the shared delivery/message/blob and second mailbox entry remain readable;
- the target-only delivery/message/raw/blob/spool data are absent;
- target connector and outbound rows are absent;
- the target activity log directory is absent;
- the purge is completed with no delivery/object work rows;
- the completed purge has no address, object key, display name, credential, or content field.

- [ ] **Step 2: Add focused failure/resume tests**

Add tests for:

1. 251 candidate deliveries require more than one worker execution and no execution processes over 250.
2. Duplicate `perform/1` calls leave counters and state correct.
3. An executing account job causes `{:snooze, 5}` before destructive stages.
4. A crash injected after database delivery deletion but before object deletion leaves outbox rows and succeeds on retry.
5. Missing raw/blob/spool/log objects complete successfully.
6. A transient error preserves stage and progress; the final configured attempt sets status `failed` with a sanitized message.
7. Retrying a failed purge resumes its existing stage/work rather than rediscovering a new purge.

- [ ] **Step 3: Run purge tests and verify RED**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_account_lifecycle/test/manifold/account_lifecycle/purge_test.exs'
```

- [ ] **Step 4: Implement stage loading and advancement**

`Purge.run/2` locks the purge for each state-changing transaction, treats `completed` as `:ok`, changes `requested` to `running`, dispatches by `stage`, and returns `{:snooze, 1}` whenever more bounded work remains. Persist a progress map with four discovery cursors (`mail`, `ingest`, `connectors`, `complete_sources`) and no PII.

Use one helper for stage changes:

```elixir
defp advance(repo, purge, next_stage) do
  purge
  |> AccountPurge.changeset(%{stage: next_stage, progress: %{}})
  |> repo.update()
end
```

- [ ] **Step 5: Implement `discover` and `drain`**

Select the first incomplete source cursor and fetch no more than 250 IDs from only that one source in an execution. `insert_all` `account_purge_deliveries` with `on_conflict: :nothing`, persist that source cursor, and snooze. Advance to `drain` only after all three sources return `done?: true`.

Persist a drain source/cursor in the purge progress map. In one execution call only one of `Connectors.cancel_account_jobs(mailbox_id, 250)`, `Outbound.cancel_account_jobs(mailbox_id, 250)`, or `Ingest.cancel_delivery_jobs(delivery_ids, 250)`. If it returns snooze, return `{:snooze, 5}`; if it reports more work, snooze for one second; otherwise advance the drain cursor. Advance the stage only after all three sources are empty and no matching job is executing.

- [ ] **Step 6: Implement connector, outbound, and mailbox-copy stages**

Each execution calls exactly one bounded context cleanup function with limit 250. For connector cleanup, wrap `Connectors.purge_account_batch(repo, mailbox_id, 250)` and insertion of returned method IDs into `account_purge_objects` in the same database transaction. Advance only when the context returns `done?: true`.

The `mailbox_copy` stage calls Mail entry cleanup and Ingest mailbox-link cleanup independently, persists completion flags, and advances only after both are empty.

- [ ] **Step 7: Implement orphan delivery cleanup transactionally**

Load at most 250 pending `account_purge_deliveries`. For each candidate:

1. Recheck `Mail.delivery_owned?/1`, `Ingest.delivery_owned?/1`, and `Connectors.delivery_owned?/1`.
2. If any is true, mark it `shared_retained` without touching the delivery or objects.
3. Otherwise, in one `Repo.transaction`, load attachment keys through Mail, call Ingest's locked orphan deletion, and insert raw/blob/spool outbox rows before commit.
4. Mark the candidate `purged` and increment only persisted aggregate counters.

Never infer ownership solely from the purge candidate table.

- [ ] **Step 8: Implement object-outbox cleanup**

For at most 250 pending rows:

| Kind | Reference check | Delete call |
| --- | --- | --- |
| `raw` | `Ingest.raw_object_referenced?/1` | `RawStore.delete/1` |
| `blob` | `Mail.blob_referenced?/1` | `BlobStore.delete/1` |
| `spool` | `Ingest.spool_path_referenced?/1` | `Spool.remove_ready_bundle/1` |
| `activity_log` | none after connector removal | `ActivityLog.delete_account/1` |

If still referenced, mark the outbox row completed without external deletion. On successful/missing deletion, mark completed. On error, increment `attempts`, store a bounded reason code and generic message (maximum 500 bytes, with no path, object key, address, or content), and return an error so Oban retries.

- [ ] **Step 9: Implement final verification and completion**

Before finalization, rerun job drain and discovery. Verify every context reports zero restrictive/account-owned rows and no pending work rows. In one transaction:

1. call `Accounts.delete_purging_account(repo, mailbox_id)`;
2. delete `account_purge_deliveries` and `account_purge_objects`;
3. set purge status/stage to `completed`, set `completed_at`, clear progress and error fields.

If a foreign-key restriction remains, keep the purge running and return to the owning cleanup stage; do not force-delete or disable constraints.

- [ ] **Step 10: Classify worker errors**

Return transient database/filesystem errors for Oban retry. For a permanent validation/invariant failure, or when `job.attempt >= job.max_attempts`, update the purge to `failed` with safe class/code/message and return `{:discard, reason}`. Never reactivate the mailbox.

- [ ] **Step 11: Verify lifecycle and affected context suites**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_account_lifecycle/test apps/manifold_accounts/test apps/manifold_connectors/test apps/manifold_ingest/test apps/manifold_mail/test apps/manifold_outbound/test apps/manifold_storage/test'
```

- [ ] **Step 12: Commit**

```bash
git add apps/manifold_account_lifecycle apps/manifold_ingest
git commit -m "feat(account-lifecycle): purge local account data asynchronously"
```

### Task 10: Add accessible icon actions and deletion status UI

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/index.ex`
- Modify: `apps/manifold_web/assets/css/app.css`
- Modify: `apps/manifold_web/test/manifold_web/account_live_test.exs`

- [ ] **Step 1: Write failing icon-action tests**

For an active account, assert icon-only controls by stable IDs:

```elixir
assert has_element?(view, "#edit-account-#{account.id}[aria-label='Edit account']")
assert has_element?(view, "#manage-account-#{account.id}[aria-label='Manage account']")
assert has_element?(view, "#disable-account-#{account.id}[aria-label='Disable account']")
assert has_element?(view, "#delete-account-#{account.id}[aria-label='Delete account']")
refute has_element?(view, "#account-#{account.id} .account-actions", "Edit")
refute has_element?(view, "#account-#{account.id} .account-actions", "Manage")
```

Assert each control is wrapped by a DuskMoon tooltip whose `content` is the same text and contains the approved MDI icon name.

- [ ] **Step 2: Write failing disable/delete dialog tests**

Test that Disable changes the receive-method state to `Disabled`, leaves the account row/data present, removes the Disable control, and preserves Edit/Manage/Delete.

Test that Delete opens `#delete-account-dialog` with `role="dialog"`, `aria-modal="true"`, account name/address, the local-data warning, and explicit remote-provider unchanged copy. Submit a wrong address and assert the inline error, no purge, and no job. Submit the exact address and assert the flash, `Deleting...`, `aria-live="polite"`, and no action buttons.

Set a purge to failed and assert `Delete failed` plus `#retry-delete-account-#{account.id}`. Delete the mailbox in the test process, send the refresh message, and assert the row disappears.

- [ ] **Step 3: Run Web test and verify RED**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_web/test/manifold_web/account_live_test.exs'
```

- [ ] **Step 4: Load account rows with lifecycle state**

Refactor `mount/3` into `load_accounts/1`. Fetch methods as today, query `AccountLifecycle.states_by_mailbox/1` once, and add `lifecycle_state` to each row. Initialize:

```elixir
delete_account: nil,
delete_confirmation: "",
delete_error: nil,
refresh_timer: nil
```

Only schedule `Process.send_after(self(), :refresh_accounts, 5_000)` when connected and at least one row has purge status `requested` or `running`. Store the timer reference, clear it in `handle_info`, reload, then conditionally schedule again. Do not poll a page containing only active, disabled, failed, or no accounts.

- [ ] **Step 5: Render the icon-only action group**

Use the established pattern:

```heex
<.dm_tooltip content="Edit account" position="bottom">
  <.link
    id={"edit-account-#{row.account.id}"}
    navigate={~p"/settings/accounts/#{row.account.id}/edit"}
    class="settings-icon-button"
    aria-label="Edit account"
  >
    <.dm_mdi name="pencil-outline" />
  </.link>
</.dm_tooltip>
```

Repeat for Manage (`cog-outline`), Disable (`account-off-outline`, button with `phx-click`), and Delete (`delete-outline`, danger class). A disabled row renders `Disabled` in the receive-method column and omits Disable. A running/requested row replaces the entire action group with `<span aria-live="polite">Deleting...</span>`. A failed row shows `Delete failed` and a retry icon button.

- [ ] **Step 6: Add lifecycle events**

Implement `disable-account`, `open-delete-account`, `validate-delete-account`, `cancel-delete-account`, `confirm-delete-account`, and `retry-delete-account`. Every event resolves IDs against fresh server data or calls a context that does so. Never trust the address stored in socket assigns for confirmation.

`confirm-delete-account` calls `AccountLifecycle.request_deletion/2`; mismatch keeps the dialog open with `delete_error`, success closes it, reloads rows, schedules polling, and flashes `Account deletion queued.`

- [ ] **Step 7: Render the accessible typed-confirmation dialog**

Follow the existing mark-all-read dialog structure and add focusable form controls:

```heex
<div
  :if={@delete_account}
  id="delete-account-dialog"
  class="account-delete-modal"
  role="dialog"
  aria-modal="true"
  aria-labelledby="delete-account-title"
  aria-describedby="delete-account-warning"
>
  <div class="account-delete-backdrop" phx-click="cancel-delete-account"></div>
  <div class="account-delete-dialog">
    <h2 id="delete-account-title">Delete account?</h2>
    <p id="delete-account-warning">
      This permanently deletes this account's local methods, credentials, messages,
      drafts, sent mail, folders, attachments, and stored objects. Mail and accounts
      held by the remote provider are not deleted.
    </p>
    <.form for={%{}} id="delete-account-form" phx-change="validate-delete-account" phx-submit="confirm-delete-account">
      <label for="delete-account-confirmation">
        Type {@delete_account.address} to confirm
      </label>
      <input id="delete-account-confirmation" name="confirmation" value={@delete_confirmation} autocomplete="off" />
      <p :if={@delete_error} id="delete-account-error" role="alert">{@delete_error}</p>
      <button type="button" phx-click="cancel-delete-account">Cancel</button>
      <button id="confirm-delete-account" type="submit" disabled={String.trim(@delete_confirmation) != @delete_account.address}>Delete local account data</button>
    </.form>
  </div>
</div>
```

- [ ] **Step 8: Add token-based styles**

Reuse `.settings-icon-button` and `.settings-icon-button-danger`. Add only layout/state/dialog selectors needed for account deletion, using `var(--color-error)`, `var(--color-error-container)`, surface/outline tokens, and `color-mix`; add no hex values or Tailwind palette classes. Match the existing mark-all-read modal positioning and narrow-screen behavior.

- [ ] **Step 9: Build assets and verify Web GREEN**

```bash
devenv shell -- mix assets.build
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_web/test/manifold_web/account_live_test.exs'
```

- [ ] **Step 10: Commit**

```bash
git add apps/manifold_web
git commit -m "feat(web): add account lifecycle icon actions"
```

### Task 11: Document ownership and run final scoped verification

**Files:**
- Create: `.agents/skills/develop/references/account-actions.md`
- Modify only if verification finds an in-scope defect: files already listed in this plan

- [ ] **Step 1: Write the feature reference**

Document:

- UI route and the four icon/tooltip labels;
- Disabled, Deleting, Delete failed, and completed behavior;
- exact-address confirmation and local-only semantics;
- `manifold_account_lifecycle` ownership;
- queue name/concurrency and worker argument;
- stage order and 250-row bound;
- target-copy versus shared-delivery ownership rule;
- object outbox/idempotence behavior;
- context API/file ownership table;
- retry and operational inspection commands;
- explicit out-of-scope remote provider and edge behavior.

- [ ] **Step 2: Format and scan the diff**

```bash
devenv shell -- mix format
git diff --check
rg -n "TODO|FIXME|delete.*provider|revoke" apps/manifold_account_lifecycle apps/manifold_accounts apps/manifold_connectors apps/manifold_ingest apps/manifold_mail apps/manifold_outbound apps/manifold_storage apps/manifold_web .agents/skills/develop/references/account-actions.md
```

Expected: the stage dispatcher covers every persisted stage; any existing unrelated TODO is unchanged; no remote provider delete/revoke call appears in the new lifecycle path.

- [ ] **Step 3: Run the complete affected-app suite**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test apps/manifold_data/test apps/manifold_accounts/test apps/manifold_account_lifecycle/test apps/manifold_storage/test apps/manifold_mail/test apps/manifold_outbound/test apps/manifold_ingest/test apps/manifold_connectors/test apps/manifold_web/test'
```

Expected: all affected-app tests pass. The pre-change baseline was 424 tests with 0 failures; the final total must be larger and have 0 failures.

- [ ] **Step 4: Run strict compilation, formatting, and frontend checks**

```bash
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix duskmoon_bundler.js.check
devenv shell -- mix assets.build
```

Expected: all four commands exit 0.

- [ ] **Step 5: Run the full suite once**

```bash
devenv shell -- bash -c 'export TEST_DATABASE_URL=postgres://manifold_dev:manifold_dev@localhost/manifold_test?socket_dir=/run/user/1000/devenv-ec2913a/postgres; exec mix test'
```

If an out-of-scope app fails, record the exact failure and stop instead of modifying that app. If an in-scope failure appears, fix only the responsible files already named in this plan and rerun its app suite before rerunning the full suite.

- [ ] **Step 6: Commit documentation and verification fixes**

```bash
git add .agents/skills/develop/references/account-actions.md
git add apps/manifold_data apps/manifold_accounts apps/manifold_account_lifecycle apps/manifold_storage apps/manifold_mail apps/manifold_outbound apps/manifold_ingest apps/manifold_connectors apps/manifold_web config/config.exs mix.exs
git commit -m "docs(accounts): record account lifecycle behavior"
```

Before committing, verify `git diff --cached --name-only` contains only files listed in this plan. If no verification fix changed code, the final commit should contain only the feature reference.
