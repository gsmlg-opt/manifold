# Microsoft 365 Receive and Send Methods Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve the production Microsoft Graph receive pipeline, add least-privilege Microsoft 365 MIME sending, and converge Microsoft's authoritative Sent Items copy into a provider-neutral local Sent folder.

**Architecture:** `manifold_connectors` extends the post-Gmail shared OAuth authorization engine to Microsoft and retains ownership of serialized token refresh, Graph delta sync, and well-known folder identity. `manifold_outbound` snapshots exact MIME bytes and the selected Microsoft method at queue time, submits those bytes through Graph, and treats ambiguous acceptance as terminal uncertainty; `manifold_mail` owns projected Sent, while `manifold_web` exposes projected Sent separately from outbound Send activity.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Ecto/PostgreSQL, Oban, Req, Microsoft Graph v1.0, ExUnit.

---

## Global constraints

- Approved spec: `docs/superpowers/specs/2026-08-11-microsoft-365-receive-send-methods-design.md`.
- Prerequisite already integrated: the Gmail shared-authorization and account-selected outbound foundation on `main` through commit `df691a5`.
- Implementation worktree: `.trees/microsoft-365-receive-send-plan`; branch: `codex/microsoft-365-receive-send-plan` until the implementation branch/worktree is selected at handoff.
- Use TDD in every behavioral task: focused failing test, minimal implementation, focused passing test, then a conventional commit.
- Microsoft means Microsoft 365 work/school accounts through tenant `organizations`; do not add `common`, `consumers`, Outlook.com, application permissions, aliases, delegated send-as, or shared-mailbox behavior.
- Request delegated `Mail.Read` for receive and `Mail.Send` for send, plus the existing identity/offline scopes. Never request `Mail.ReadWrite`.
- Preserve the existing Graph delta/raw-MIME ingestion boundary, immutable Graph IDs, opaque authority-validated continuation URLs, five-minute polling, and manual synchronization. Do not add webhooks.
- One Microsoft OAuth authorization belongs to one Manifold account. Its Graph subject and canonical address are immutable bindings; receive and send are independent method references to that authorization.
- Graph Sent Items is authoritative. Never create an optimistic projected Sent message after outbound acceptance and never create a direct outbound-to-projected-message relationship in this version.
- Newly queued Microsoft mail must snapshot the selected method and exact MIME payload and must never fall back to Resend. Existing queued Resend work remains dispatchable.
- Automatic retry is permitted only for explicit `429` and transport failure proven before dispatch. Every Microsoft `5xx`, post-dispatch loss, and unclassified transport outcome becomes `submission_uncertain` with no automatic resend.
- Tokens, authorization codes, MIME, addresses, recipients, subjects, bodies, and Bcc values must not appear in logs, telemetry, provider metadata, activity metadata, or Oban arguments.
- Run repository commands with `devenv shell --` unless already inside the devenv shell. Run only the scoped tests listed in each task; if an out-of-scope suite fails, report it and stop instead of repairing unrelated code.
- Do not edit the integrated Gmail migrations `20260811000500`, `20260811000600`, or `20260811000700`; add forward migrations dated `20260812`.

## File map

### Provider-neutral Sent

- Create: `apps/manifold_data/priv/repo/migrations/20260812000100_add_sent_system_folders.exs` — widen the folder-kind constraint, safely rename a pre-existing custom `Sent`, and insert exactly one system Sent row per existing mailbox.
- Modify: `apps/manifold_mail/lib/manifold/mail/schema/folder.ex` — accept `sent`.
- Modify: `apps/manifold_mail/lib/manifold/mail/folders.ex` — create, return, and find Sent and repair a custom-name collision before lazy system-folder creation.
- Modify: `apps/manifold_mail/lib/manifold/mail/mailbox.ex` — sort Sent and allow restore to a previous Sent folder.
- Modify: `apps/manifold_mail/lib/manifold/mail/external_state.ex` — place provider messages into Sent.
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex` — preserve normalized `sent` remote state.
- Modify: `apps/manifold_mail/test/manifold/mail/mailbox_test.exs` — folder creation/order, custom-name preservation, and Sent restore.
- Modify: `apps/manifold_mail/test/manifold/mail/external_state_test.exs` — external Sent placement.
- Modify: `apps/manifold_connectors/test/manifold/connectors_test.exs` — connector-to-mail Sent normalization.

### Shared Microsoft authorization and receive mapping

- Create: `apps/manifold_data/priv/repo/migrations/20260812000200_add_shared_microsoft_authorizations.exs` — widen authorization/send-method constraints and move legacy Microsoft OAuth rows into the shared authorization table without changing their authenticated encryption context.
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/oauth_authorization.ex` — accept Microsoft.
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/send_method.ex` — accept Microsoft send methods.
- Create: `apps/manifold_connectors/lib/manifold/connectors/microsoft_scopes.ex` — canonical Microsoft delegated scope constants.
- Create: `apps/manifold_connectors/lib/manifold/connectors/oauth_scopes.ex` — provider-neutral identity, purpose, and approved-scope registry for Gmail and Microsoft.
- Move: `apps/manifold_connectors/lib/manifold/connectors/gmail_authorizations.ex` to `apps/manifold_connectors/lib/manifold/connectors/oauth_authorizations.ex` — make the existing locking, refresh, binding, lifecycle, and cleanup engine provider-neutral.
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth.ex` — allow Microsoft send and union existing Microsoft grants into incremental consent.
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex` — route both OAuth providers through one lifecycle, expose method setup state, and check out Microsoft send methods.
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex` — use shared authorization for Microsoft receive, generalize reconnect handling, and invoke folder-map reconciliation.
- Modify: `apps/manifold_connectors/lib/manifold/connectors/view.ex` — expose a redacted OAuth method setup state to settings UI.
- Create: `apps/manifold_connectors/lib/manifold/connectors/microsoft_folder_mapping.ex` — reconcile mapping metadata, remote-message folder kinds, and ApplyRemoteState jobs without touching cursor positions or raw mail.
- Create: `apps/manifold_connectors/lib/manifold/connectors/remote_state_jobs.ex` — share the unique ApplyRemoteState job insertion boundary between normal Sync and mapping repair.
- Modify: `apps/manifold_connectors/lib/manifold/connectors/provider.ex` — add a normalized well-known-folder mapping result/callback.
- Modify: `apps/manifold_connectors/lib/manifold/connectors/provider/microsoft_graph.ex` — resolve well-known IDs, classify folders by ID, and bound initial delta requests.
- Rename/modify: `apps/manifold_connectors/test/manifold/connectors/schema/gmail_authorization_test.exs` to `apps/manifold_connectors/test/manifold/connectors/schema/oauth_authorization_test.exs` — provider-neutral schema and database constraints.
- Keep and modify: `apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs` — Gmail regression coverage for the extracted engine.
- Create: `apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs` — Microsoft binding, scope upgrade, refresh, disconnect, and reconnect behavior.
- Modify: `apps/manifold_connectors/test/manifold/connectors/oauth_test.exs` — Microsoft receive/send scope snapshots and unions.
- Modify: `apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs` — Microsoft method checkout and stale-snapshot fences.
- Modify: `apps/manifold_connectors/test/manifold/connectors/provider/microsoft_graph_test.exs` — well-known lookups, localized folders, bounded delta, reset, and authority tests.
- Modify: `apps/manifold_connectors/test/manifold/connectors/sync_test.exs` — shared token use and in-place historical mapping repair.
- Modify: `apps/manifold_connectors/test/manifold/connectors_test.exs` — migration-compatible Microsoft lifecycle and job preservation.
- Modify: `apps/manifold_data/test/manifold/config_test.exs` — retain `organizations` as the tenant default.

### Immutable outbound payload and Microsoft submission

- Create: `apps/manifold_data/priv/repo/migrations/20260812000300_add_microsoft_provider_payloads.exs` — add payload/render/sender snapshot columns and permit Microsoft provider submissions.
- Modify: `apps/manifold_outbound/lib/manifold/outbound/schema/provider_submission.ex` — persist and redact exact MIME payloads, render version, and canonical sender.
- Modify: `apps/manifold_outbound/lib/manifold/outbound/rfc_message.ex` — render Microsoft MIME with Gmail-style Bcc semantics.
- Modify: `apps/manifold_outbound/lib/manifold/outbound/provider.ex` — register Microsoft and allow a nullable provider message ID.
- Create: `apps/manifold_outbound/lib/manifold/outbound/provider/microsoft_graph.ex` — direct MIME `/me/sendMail` adapter with conservative uncertainty classification.
- Modify: `apps/manifold_outbound/lib/manifold/outbound.ex` — render once and snapshot exact bytes at queue time.
- Modify: `apps/manifold_outbound/lib/manifold/outbound/submission.ex` — load and hash persisted bytes before credential checkout, dispatch Microsoft, persist bodyless acceptance, and generalize reconnect fences.
- Modify: `apps/manifold_outbound/lib/manifold/outbound/jobs/submit_outbound.ex` — retain no-retry terminal handling for uncertainty.
- Modify: `apps/manifold_outbound/test/manifold/outbound/rfc_message_test.exs` — Microsoft MIME/Bcc fixture.
- Create: `apps/manifold_outbound/test/manifold/outbound/provider/microsoft_graph_test.exs` — Graph request and classification contract.
- Modify: `apps/manifold_outbound/test/manifold/outbound_test.exs` — queue-time payload and method snapshot tests.
- Modify: `apps/manifold_outbound/test/manifold/outbound/submission_test.exs` — identical-byte retry, nullable provider ID, reconnect, and uncertainty tests.
- Modify: `apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs` — retry/no-retry job outcomes.

### Settings, projected Sent, Send activity, and documentation

- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/receive_method_new.ex` — symmetric Microsoft receive add/upgrade flow.
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/send_method_new.ex` — Microsoft card and connect/add/upgrade confirmation.
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/show.ex` — Microsoft labels and shared reconnect impact.
- Modify: `apps/manifold_web/lib/manifold_web/router.ex` — add Send activity routes and legacy Sent redirects.
- Create: `apps/manifold_web/lib/manifold_web/controllers/sent_redirect_controller.ex` — route `/sent` to projected Sent and old outbound detail URLs to Send activity.
- Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex` — separate projected Sent navigation from outbound Send activity and navigate queued mail to Send activity detail.
- Modify: `apps/manifold_outbound/lib/manifold/outbound.ex` — rename outbound Sent query APIs to Send activity.
- Modify: `apps/manifold_outbound/lib/manifold/outbound/view.ex` — rename outbound Sent view structs to SendActivity structs.
- Modify: `apps/manifold_web/test/manifold_web/account_live_test.exs` — Microsoft setup/reconnect presentation.
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs` — purpose-correct Microsoft OAuth callbacks and safe failures.
- Modify: `apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs` — projected Sent versus Send activity and compose redirects.
- Create: `apps/manifold_web/test/manifold_web/sent_redirect_controller_test.exs` — legacy route compatibility.
- Modify: `apps/manifold_account_lifecycle/test/manifold/account_lifecycle/purge_test.exs` — purge Microsoft authorization/method/cursor/job residue and Sent rows.
- Create: `docs/adr/0011-microsoft-graph-send-and-authoritative-sent.md` — outbound Graph and authoritative Sent decision.
- Modify: `docs/adr/0007-read-only-provider-connectors.md` — keep receive read-only while documenting separately authorized send.
- Modify: `docs/adr/0010-account-selected-outbound-methods.md` — Microsoft provider routing and immutable payloads.
- Modify: `docs/DESIGN.md` — shared Microsoft OAuth, folder mapping, Sent, Send activity, and uncertainty.
- Modify: `README.md` — operator permissions, callback, incremental consent, and Sent delay.
- Modify: `.agents/skills/develop/references/gmail-shared-authorizations.md` — provider-neutral engine ownership after extraction.
- Modify: `.agents/skills/develop/references/microsoft-365-receive-send-methods.md` — implemented ownership, validation evidence, and external staging status.

## Dependency order

Tasks 1 and 2 establish the Sent data contract. Tasks 3 through 5 establish the shared Microsoft authorization and method checkout contract. Task 6 implements Graph's HTTP mapping boundary, and Task 7 depends on it to repair stored sync state. Task 8 creates immutable payload storage; Tasks 9 and 10 then implement and dispatch the Microsoft provider. Tasks 11 and 12 depend on those public contracts for settings and Web routing. Tasks 13 and 14 finish lifecycle, observability, documentation, and verification.

The approved design's compatibility list names authorization backfill before Sent creation. These two migrations have no data dependency; this plan lands provider-neutral Sent first so Graph mapping tests have their destination contract from the start. A production deployment still applies all three `20260812` migrations in one drained, non-rolling cutover, and no authorization/token row is read by the Sent migration.

### Task 1: Add the Sent system-folder data contract

**Files:**
- Create: `apps/manifold_data/priv/repo/migrations/20260812000100_add_sent_system_folders.exs`
- Modify: `apps/manifold_mail/lib/manifold/mail/schema/folder.ex:7-34`
- Modify: `apps/manifold_mail/lib/manifold/mail/folders.ex:7-52`
- Modify: `apps/manifold_mail/lib/manifold/mail/mailbox.ex:25-72`
- Modify: `apps/manifold_mail/test/manifold/mail/mailbox_test.exs`

**Contract:** `Folders.ensure/1` returns `%{inbox:, archive:, sent:, trash:}`. System-folder order is Inbox, Archive, Sent, Trash, then custom folders. A custom folder previously named `Sent` keeps every entry but is renamed to `Sent (custom <folder UUID>)` so the reserved system folder can be created.

- [ ] **Step 1: Write failing folder tests**

Add these focused assertions to `mailbox_test.exs` using its existing mailbox fixtures:

```elixir
test "ensures one ordered Sent system folder for a new mailbox" do
  mailbox_id = mailbox_fixture()

  assert {:ok, folders} = Mail.list_folders(mailbox_id)
  assert Enum.map(folders, &{&1.kind, &1.name}) == [
           {"inbox", "Inbox"},
           {"archive", "Archive"},
           {"sent", "Sent"},
           {"trash", "Trash"}
         ]

  assert Repo.aggregate(
           from(folder in Folder,
             where: folder.mailbox_id == ^mailbox_id and folder.kind == "sent"
           ),
           :count
         ) == 1
end

test "preserves a custom Sent folder and its entries while reserving system Sent" do
  mailbox_id = mailbox_fixture()
  custom =
    %Folder{}
    |> Folder.changeset(%{mailbox_id: mailbox_id, kind: "custom", name: "Sent"})
    |> Repo.insert!()

  %{entry: entry} =
    projected_message_fixture(
      mailbox_id,
      custom.id,
      nil,
      "Custom Sent message",
      DateTime.utc_now()
    )

  assert {:ok, folders} = Mail.list_folders(mailbox_id)
  system_sent = Enum.find(folders, &(&1.kind == "sent"))
  renamed = Repo.get!(Folder, custom.id)

  assert renamed.name == "Sent (custom #{custom.id})"
  assert renamed.normalized_name == String.downcase(renamed.name)
  assert Repo.get!(MailboxEntry, entry.id).folder_id == renamed.id
  assert system_sent.name == "Sent"
end
```

- [ ] **Step 2: Run the focused test and confirm the missing contract**

```sh
devenv shell -- mix test apps/manifold_mail/test/manifold/mail/mailbox_test.exs
```

Expected: FAIL because `sent` is rejected or absent and `Folders.ensure/1` returns only three system folders.

- [ ] **Step 3: Add the forward/backward migration**

Implement the migration with these exact operations:

```elixir
defmodule Manifold.Repo.Migrations.AddSentSystemFolders do
  use Ecto.Migration

  def up do
    drop(constraint(:mailbox_folders, :mailbox_folders_kind_valid))

    create(
      constraint(:mailbox_folders, :mailbox_folders_kind_valid,
        check: "kind IN ('inbox', 'archive', 'sent', 'trash', 'custom')"
      )
    )

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM mailbox_folders AS custom_sent
        JOIN mailbox_folders AS conflict
          ON conflict.mailbox_id = custom_sent.mailbox_id
         AND conflict.id <> custom_sent.id
         AND conflict.normalized_name =
           lower('Sent (custom ' || custom_sent.id::text || ')')
        WHERE custom_sent.kind = 'custom'
          AND custom_sent.normalized_name = 'sent'
      ) THEN
        RAISE EXCEPTION 'cannot reserve Sent because the deterministic custom-folder name is occupied';
      END IF;
    END
    $$
    """)

    execute("""
    UPDATE mailbox_folders
    SET name = 'Sent (custom ' || id::text || ')',
        normalized_name = lower('Sent (custom ' || id::text || ')'),
        updated_at = NOW()
    WHERE kind = 'custom' AND normalized_name = 'sent'
    """)

    execute("""
    INSERT INTO mailbox_folders
      (id, mailbox_id, kind, name, normalized_name, inserted_at, updated_at)
    SELECT gen_random_uuid(), mailbox.id, 'sent', 'Sent', 'sent', NOW(), NOW()
    FROM mailboxes AS mailbox
    WHERE NOT EXISTS (
      SELECT 1 FROM mailbox_folders AS folder
      WHERE folder.mailbox_id = mailbox.id AND folder.kind = 'sent'
    )
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM mailbox_entries AS entry
        JOIN mailbox_folders AS folder
          ON folder.id = entry.folder_id OR folder.id = entry.previous_folder_id
        WHERE folder.kind = 'sent'
      ) THEN
        RAISE EXCEPTION 'cannot rollback Sent folders while Sent contains mailbox entries';
      END IF;
    END
    $$
    """)

    execute("DELETE FROM mailbox_folders WHERE kind = 'sent'")

    execute("""
    UPDATE mailbox_folders
    SET name = 'Sent', normalized_name = 'sent', updated_at = NOW()
    WHERE kind = 'custom'
      AND name = 'Sent (custom ' || id::text || ')'
      AND normalized_name = lower('Sent (custom ' || id::text || ')')
    """)

    drop(constraint(:mailbox_folders, :mailbox_folders_kind_valid))

    create(
      constraint(:mailbox_folders, :mailbox_folders_kind_valid,
        check: "kind IN ('inbox', 'archive', 'trash', 'custom')"
      )
    )
  end
end
```

- [ ] **Step 4: Extend schema and lazy creation**

Use these exact allowlists and return shape:

```elixir
# folder.ex
@kinds ~w(inbox archive sent trash custom)

# folders.ex
@system_folders [
  {"inbox", "Inbox"},
  {"archive", "Archive"},
  {"sent", "Sent"},
  {"trash", "Trash"}
]

@spec ensure(Ecto.UUID.t()) ::
        {:ok, %{inbox: Folder.t(), archive: Folder.t(), sent: Folder.t(), trash: Folder.t()}}

@spec get_system(Ecto.UUID.t(), String.t()) :: Folder.t() | nil
def get_system(mailbox_id, kind) when kind in ~w(inbox archive sent trash) do
  Repo.get_by(Folder, mailbox_id: mailbox_id, kind: kind)
end
```

Before `insert_all/3`, lock and rename any custom `normalized_name == "sent"` using the same `Sent (custom <id>)` form as the migration. Return `:system_folders_unavailable` unless all four keys are present. Update `Mailbox.list_folders/1` ordering to:

```elixir
defp reserve_sent_name(mailbox_id) do
  Folder
  |> where([folder],
    folder.mailbox_id == ^mailbox_id and folder.kind == "custom" and
      folder.normalized_name == "sent")
  |> lock("FOR UPDATE")
  |> Repo.all()
  |> Enum.reduce_while(:ok, fn folder, :ok ->
    name = "Sent (custom #{folder.id})"

    case folder |> Folder.changeset(%{name: name}) |> Repo.update() do
      {:ok, _renamed} -> {:cont, :ok}
      {:error, changeset} -> {:halt, {:error, changeset}}
    end
  end)
end
```

Call this inside the transaction-wrapped `Folders.ensure/1` before `insert_all/3`:

```elixir
def ensure(mailbox_id) do
  Repo.transaction(fn ->
    with :ok <- reserve_sent_name(mailbox_id) do
      insert_system_folders(mailbox_id)

      case load_system_folders(mailbox_id) do
        %{inbox: _, archive: _, sent: _, trash: _} = folders -> folders
        _incomplete -> Repo.rollback(:system_folders_unavailable)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end)
  |> case do
    {:ok, folders} -> {:ok, folders}
    {:error, reason} -> {:error, reason}
  end
end
```

`insert_system_folders/1` and `load_system_folders/1` are the current insert/query bodies extracted without semantic changes except the four-folder list. Then update `Mailbox.list_folders/1` ordering to:

```elixir
fragment(
  "CASE ? WHEN 'inbox' THEN 0 WHEN 'archive' THEN 1 WHEN 'sent' THEN 2 WHEN 'trash' THEN 3 ELSE 4 END",
  folder.kind
)
```

- [ ] **Step 5: Run migration and folder tests**

```sh
devenv shell -- mix ecto.migrate
devenv shell -- mix test apps/manifold_mail/test/manifold/mail/mailbox_test.exs
```

Expected: migration succeeds; both tests pass; repeated `Mail.list_folders/1` calls still leave one Sent row.

- [ ] **Step 6: Commit the Sent data contract**

```sh
git add -- apps/manifold_data/priv/repo/migrations/20260812000100_add_sent_system_folders.exs \
  apps/manifold_mail/lib/manifold/mail/schema/folder.ex \
  apps/manifold_mail/lib/manifold/mail/folders.ex \
  apps/manifold_mail/lib/manifold/mail/mailbox.ex \
  apps/manifold_mail/test/manifold/mail/mailbox_test.exs
git commit -m "feat(mail): add Sent system folder"
```

### Task 2: Place and restore projected messages in Sent

**Files:**
- Modify: `apps/manifold_mail/lib/manifold/mail/external_state.ex:9-73`
- Modify: `apps/manifold_mail/lib/manifold/mail/mailbox.ex:438-484`
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex:1337-1340`
- Modify: `apps/manifold_mail/test/manifold/mail/external_state_test.exs`
- Modify: `apps/manifold_mail/test/manifold/mail/mailbox_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors_test.exs`

- [ ] **Step 1: Write failing Sent placement and restore tests**

Add one external-state test that applies:

```elixir
assert {:ok, :applied} =
         Mail.apply_external_state(mailbox.id, delivery.id, %{
           folder_kind: "sent",
           read?: true,
           starred?: false,
           deleted?: false
         })

sent = Repo.get_by!(Folder, mailbox_id: mailbox.id, kind: "sent")
assert Repo.get_by!(MailboxEntry, inbound_delivery_id: delivery.id).folder_id == sent.id
```

Add one mailbox test that starts an entry in Sent, calls `Mail.trash/2`, then `Mail.restore/2`, and asserts its `folder_id` returns to Sent and `previous_folder_id` is cleared. Add a connector test whose imported `RemoteMessage.remote_folder_kind` is `"sent"` and assert `Connectors.apply_remote_state/1` places the entry in Sent rather than Archive.

- [ ] **Step 2: Run tests and verify Sent is currently normalized away**

```sh
devenv shell -- mix test \
  apps/manifold_mail/test/manifold/mail/external_state_test.exs \
  apps/manifold_mail/test/manifold/mail/mailbox_test.exs \
  apps/manifold_connectors/test/manifold/connectors_test.exs
```

Expected: FAIL because external state and connector normalization accept only Inbox/Archive/Trash and restore excludes Sent.

- [ ] **Step 3: Widen only the three folder-kind boundaries**

Apply these exact changes:

```elixir
# Manifold.Mail.ExternalState
@folder_kinds ~w(inbox archive sent trash)

# Manifold.Connectors
defp normalize_folder_kind(folder_kind)
     when folder_kind in ~w(inbox archive sent trash),
     do: folder_kind

# Manifold.Mail.Mailbox.restore/2
valid_target_ids =
  Folder
  |> where(
    [folder],
    folder.mailbox_id == ^mailbox_id and folder.kind in ^~w(inbox archive sent custom)
  )
  |> select([folder], folder.id)
  |> Repo.all()
  |> MapSet.new()
```

Keep Sent entries' existing archive/trash actions and do not enqueue remote write-back.

- [ ] **Step 4: Run focused tests**

```sh
devenv shell -- mix test \
  apps/manifold_mail/test/manifold/mail/external_state_test.exs \
  apps/manifold_mail/test/manifold/mail/mailbox_test.exs \
  apps/manifold_connectors/test/manifold/connectors_test.exs
```

Expected: all focused tests pass.

- [ ] **Step 5: Commit projected Sent behavior**

```sh
git add -- apps/manifold_mail/lib/manifold/mail/external_state.ex \
  apps/manifold_mail/lib/manifold/mail/mailbox.ex \
  apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_mail/test/manifold/mail/external_state_test.exs \
  apps/manifold_mail/test/manifold/mail/mailbox_test.exs \
  apps/manifold_connectors/test/manifold/connectors_test.exs
git commit -m "feat(mail): project provider messages into Sent"
```

### Task 3: Migrate legacy Microsoft OAuth into shared authorizations

**Files:**
- Create: `apps/manifold_data/priv/repo/migrations/20260812000200_add_shared_microsoft_authorizations.exs`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/oauth_authorization.ex:7-76`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/send_method.ex:7-52`
- Rename/modify: `apps/manifold_connectors/test/manifold/connectors/schema/gmail_authorization_test.exs` to `apps/manifold_connectors/test/manifold/connectors/schema/oauth_authorization_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors_test.exs`

**Migration invariant:** For each legacy Microsoft receive method, create `connector_oauth_authorizations.id = connector_accounts.id`, copy the legacy credential ciphertext unchanged, set `oauth_authorization_id`, re-anchor connector events to the authorization, and delete only that method's migrated OAuth credential. The identical UUID preserves AES-GCM associated data `credential:<id>:access|refresh`; cursors, remote mappings, and Oban arguments continue to reference the unchanged receive-method ID.

- [ ] **Step 1: Write failing schema and constraint tests**

Rename the schema test to provider-neutral terminology and add:

```elixir
test "Microsoft authorization and send method are accepted" do
  authorization =
    OAuthAuthorization.changeset(%OAuthAuthorization{}, %{
      account_id: Ecto.UUID.generate(),
      provider: "microsoft",
      provider_subject_id: "graph-user-1",
      email_address: "person@example.test",
      granted_scopes: ["Mail.Read", "offline_access"],
      status: "connected",
      refresh_token_ciphertext: <<1, 2, 3>>
    })

  assert authorization.valid?

  method =
    SendMethod.changeset(%SendMethod{}, %{
      account_id: Ecto.UUID.generate(),
      oauth_authorization_id: Ecto.UUID.generate(),
      kind: "microsoft",
      email_address: "person@example.test",
      status: "connected",
      enabled: true
    })

  assert method.valid?
end
```

Extend the database constraint test to insert distinct Microsoft authorizations for distinct accounts, reject duplicate `{account_id, provider}`, reject a duplicate `{provider, provider_subject_id}`, and reject an unsupported provider/kind.

- [ ] **Step 2: Run the schema test and verify failure**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/schema/oauth_authorization_test.exs
```

Expected: FAIL because the Ecto and PostgreSQL allowlists contain only Gmail/SMTP.

- [ ] **Step 3: Implement the non-rolling Microsoft migration**

The migration must begin with the same drain warning as the Gmail cutover and perform these operations in order:

```elixir
defp preflight_legacy_microsoft_receive_methods! do
  duplicate = repo().query!("""
  SELECT mailbox_id::text, COUNT(*)
  FROM connector_accounts
  WHERE provider = 'microsoft'
  GROUP BY mailbox_id
  HAVING COUNT(*) > 1
  ORDER BY mailbox_id
  LIMIT 1
  """).rows

  case duplicate do
    [[mailbox_id, count]] ->
      raise "cannot migrate shared Microsoft authorizations: mailbox #{mailbox_id} has #{count} Microsoft receive methods"
    [] ->
      :ok
  end

  mismatch = repo().query!("""
  SELECT receive_method.id::text, receive_method.email_address,
         mailbox.local_part || '@' || domain.normalized_domain
  FROM connector_accounts AS receive_method
  JOIN mailboxes AS mailbox ON mailbox.id = receive_method.mailbox_id
  JOIN domains AS domain ON domain.id = mailbox.domain_id
  WHERE receive_method.provider = 'microsoft'
    AND lower(receive_method.email_address) <>
        lower(mailbox.local_part || '@' || domain.normalized_domain)
  ORDER BY receive_method.id
  LIMIT 1
  """).rows

  case mismatch do
    [[method_id, _provider_address, _account_address]] ->
      raise "cannot migrate Microsoft receive method #{method_id}: canonical address mismatch"
    [] ->
      :ok
  end
end

drop(constraint(:connector_oauth_authorizations, :oauth_authorizations_provider_valid))
create(constraint(:connector_oauth_authorizations, :oauth_authorizations_provider_valid,
  check: "provider IN ('gmail', 'microsoft')"))

drop(constraint(:connector_send_methods, :connector_send_methods_kind_valid))
create(constraint(:connector_send_methods, :connector_send_methods_kind_valid,
  check: "kind IN ('smtp', 'gmail', 'microsoft')"))
```

Use an `INSERT ... SELECT` matching the Gmail migration's columns, with `provider = 'microsoft'`, authorization/receive ID reuse, copied `legacy_credential_id`, copied token ciphertext/expiry/key/lock fields, sorted existing scopes, and status normalization. Then:

```sql
UPDATE connector_accounts AS receive_method
SET oauth_authorization_id = authorization.id
FROM connector_oauth_authorizations AS authorization
WHERE authorization.id = receive_method.id
  AND authorization.provider = 'microsoft'
  AND receive_method.provider = 'microsoft';

UPDATE connector_events AS event
SET oauth_authorization_id = receive_method.oauth_authorization_id,
    external_account_id = NULL
FROM connector_accounts AS receive_method
WHERE event.external_account_id = receive_method.id
  AND receive_method.provider = 'microsoft'
  AND receive_method.oauth_authorization_id IS NOT NULL;

DELETE FROM connector_credentials AS credential
USING connector_accounts AS receive_method
WHERE credential.external_account_id = receive_method.id
  AND credential.secret_kind = 'oauth'
  AND receive_method.provider = 'microsoft'
  AND receive_method.oauth_authorization_id = receive_method.id;
```

`down/0` must refuse rollback while a Microsoft send method exists, while an authorization cannot map back to exactly one Microsoft receive method, while credential restoration would collide, or while token material cannot satisfy the legacy credential constraint. Restore events to the receive-method anchor, restore `connector_credentials` under `COALESCE(legacy_credential_id, authorization.id)`, clear Microsoft receive links, delete only Microsoft authorizations, and restore the previous Gmail-only/SMTP-Gmail checks.

- [ ] **Step 4: Extend the Ecto allowlists**

```elixir
# oauth_authorization.ex
@providers ~w(gmail microsoft)

# send_method.ex
@kinds ~w(smtp gmail microsoft)
```

- [ ] **Step 5: Add migration-preservation assertions**

In `connectors_test.exs`, add a latest-schema preservation fixture shaped exactly like the migrated result and assert:

```elixir
assert authorization.id == receive_method.id
assert receive_method.oauth_authorization_id == authorization.id
refute Repo.get_by(Credential, external_account_id: receive_method.id)
assert Crypto.decrypt(authorization.access_token_ciphertext, "credential:#{receive_method.id}:access") ==
         {:ok, "legacy-access"}
assert Crypto.decrypt(authorization.refresh_token_ciphertext, "credential:#{receive_method.id}:refresh") ==
         {:ok, "legacy-refresh"}
assert Repo.get!(SyncCursor, cursor.id).committed_cursor == committed_url
assert Repo.get!(RemoteMessage, remote.id).provider_message_id == provider_message_id
assert Repo.get!(Oban.Job, job.id).args == %{"external_account_id" => receive_method.id}
assert Enum.all?(Repo.all(ConnectorEvent), &(&1.oauth_authorization_id == authorization.id))
```

This focused test protects the post-migration encryption and reference invariants. Task 14 performs the actual old-schema-to-new-schema migration rehearsal in a dedicated disposable database; do not alter the normal ExUnit database schema inside a test process.

- [ ] **Step 6: Run the migration/schema tests**

```sh
devenv shell -- mix ecto.migrate
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/schema/oauth_authorization_test.exs \
  apps/manifold_connectors/test/manifold/connectors_test.exs
```

Expected: Microsoft constraints pass; migrated ciphertext decrypts with the unchanged ID; cursor, mapping, job, status, and event assertions pass.

- [ ] **Step 7: Commit shared Microsoft storage**

```sh
git add -- apps/manifold_data/priv/repo/migrations/20260812000200_add_shared_microsoft_authorizations.exs \
  apps/manifold_connectors/lib/manifold/connectors/schema/oauth_authorization.ex \
  apps/manifold_connectors/lib/manifold/connectors/schema/send_method.ex \
  apps/manifold_connectors/test/manifold/connectors/schema/oauth_authorization_test.exs \
  apps/manifold_connectors/test/manifold/connectors_test.exs
git commit -m "feat(connectors): share Microsoft OAuth authorization storage"
```

### Task 4: Generalize OAuth scopes, completion, refresh, and direction lifecycle

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/microsoft_scopes.ex`
- Create: `apps/manifold_connectors/lib/manifold/connectors/oauth_scopes.ex`
- Move: `apps/manifold_connectors/lib/manifold/connectors/gmail_authorizations.ex` to `apps/manifold_connectors/lib/manifold/connectors/oauth_authorizations.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth.ex:1-375`
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex:1-145`
- Modify: `apps/manifold_connectors/test/manifold/connectors/oauth_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs`
- Create: `apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs`

**Public interfaces:**

```elixir
OAuthScopes.identity(provider) :: [String.t()]
OAuthScopes.purpose(provider, :receive | :send) :: {:ok, [String.t()]} | :error
OAuthScopes.method_scope(provider, :receive | :send) :: {:ok, String.t()} | :error
OAuthScopes.approved?(provider, scope) :: boolean()

OAuthAuthorizations.complete(provider, code, consumed, adapter, config, opts)
OAuthAuthorizations.add_authorized_method(provider, account_id, purpose, adapter, config, opts)
OAuthAuthorizations.checkout_access_token(authorization_id, adapter, config, opts)
OAuthAuthorizations.disconnect_method(direction, account_id, method_id)
OAuthAuthorizations.delete_receive_method(method_id)
OAuthAuthorizations.mark_reconnect_required(authorization_id, provider_error, opts)
OAuthAuthorizations.mark_send_reconnect_required(method_id, expected_access_token, error_code, opts)
```

- [ ] **Step 1: Write failing Microsoft OAuth scope tests**

Replace the test that expects Microsoft send to be unsupported with these assertions:

```elixir
@microsoft_redirect "https://mail.example.test/connectors/microsoft/callback"

test "Microsoft receive and send starts snapshot least-privilege purpose scopes", %{mailbox: mailbox} do
  assert {:ok, receive} =
           OAuth.start("microsoft", mailbox.id, @microsoft_redirect, purpose: :receive)
  assert MapSet.new(authorization_scopes(receive.url)) ==
           MapSet.new(~w(openid profile offline_access User.Read Mail.Read))

  assert {:ok, send} =
           OAuth.start("microsoft", mailbox.id, @microsoft_redirect, purpose: :send)
  assert MapSet.new(authorization_scopes(send.url)) ==
           MapSet.new(~w(openid profile offline_access User.Read Mail.Send))

  refute String.contains?(send.url, "Mail.ReadWrite")
end

test "Microsoft incremental consent unions the existing grant in both directions", %{mailbox: mailbox} do
  receive_only = insert_microsoft_authorization!(mailbox.id, ~w(Mail.Read offline_access))
  assert {:ok, send} = OAuth.start("microsoft", receive_only.account_id, @microsoft_redirect,
    purpose: :send)
  assert MapSet.subset?(
           MapSet.new(~w(Mail.Read Mail.Send offline_access)),
           MapSet.new(authorization_scopes(send.url))
         )

  Repo.delete!(receive_only)
  send_only = insert_microsoft_authorization!(mailbox.id, ~w(Mail.Send offline_access))
  assert {:ok, receive} = OAuth.start("microsoft", send_only.account_id, @microsoft_redirect,
    purpose: :receive)
  assert MapSet.subset?(
           MapSet.new(~w(Mail.Read Mail.Send offline_access)),
           MapSet.new(authorization_scopes(receive.url))
         )
end

defp insert_microsoft_authorization!(account_id, scopes) do
  %OAuthAuthorization{}
  |> OAuthAuthorization.changeset(%{
    account_id: account_id,
    provider: "microsoft",
    provider_subject_id: "graph-sub-#{System.unique_integer([:positive])}",
    email_address: "person@oauth.test",
    granted_scopes: scopes,
    status: "connected",
    key_version: 1,
    access_token_ciphertext: <<1, 2, 3>>,
    refresh_token_ciphertext: <<4, 5, 6>>
  })
  |> Repo.insert!()
end
```

In the new `microsoft_authorizations_test.exs`, add a table-driven completion matrix for new receive-only, new send-only, receive-to-send, and send-to-receive. Each case must assert one shared authorization, the requested method only or both methods as appropriate, exact granted-scope union, exact subject/address binding, and one unique sync job only when receive exists.

- [ ] **Step 2: Add failing lifecycle and refresh tests**

Cover these concrete outcomes in `microsoft_authorizations_test.exs`:

```elixir
test "an incremental response without refresh_token retains existing ciphertext"
test "an incremental response with refresh_token rotates it atomically"
test "subject mismatch leaves authorization and methods unchanged"
test "canonical address mismatch creates no authorization or method"
test "a subject already bound to another account is rejected"
test "a missing old or new required scope creates no method"
test "an inactive account at callback creates no method"
test "concurrent receive and send checkout performs one refresh request"
test "disconnecting receive leaves a healthy send reference and token ciphertext"
test "disconnecting the final method erases ciphertext and disconnects authorization"
test "invalid_grant marks the authorization and both methods reconnect_required"
test "adding Microsoft Send disables only the previously enabled send method"
test "adding Microsoft Receive preserves the independent enabled send method"
```

For the concurrent refresh test, expire one authorization, block the fake adapter's first `refresh_token/3`, start receive and send checkout tasks, release the barrier, then assert both receive the rotated access token and the fake observed exactly one refresh call.

- [ ] **Step 3: Run the tests and verify the Gmail-specific boundary fails**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs
```

Expected: Microsoft cases fail because send is rejected and completion/checkout/lifecycle route only through `GmailAuthorizations`; existing Gmail tests remain the extraction regression baseline.

- [ ] **Step 4: Add canonical scope modules**

Implement the constants and registry exactly:

```elixir
defmodule Manifold.Connectors.MicrosoftScopes do
  @moduledoc false

  def read, do: "Mail.Read"
  def send, do: "Mail.Send"
  def offline, do: "offline_access"
end

defmodule Manifold.Connectors.OAuthScopes do
  @moduledoc false

  alias Manifold.Connectors.{GmailScopes, MicrosoftScopes}

  def identity("gmail"), do: ["openid", "email"]
  def identity("microsoft"), do: ["openid", "profile", "User.Read"]

  def purpose("gmail", :receive), do: {:ok, [GmailScopes.read()]}
  def purpose("gmail", :send), do: {:ok, [GmailScopes.send()]}
  def purpose("microsoft", :receive), do: {:ok, [MicrosoftScopes.read(), MicrosoftScopes.offline()]}
  def purpose("microsoft", :send), do: {:ok, [MicrosoftScopes.send(), MicrosoftScopes.offline()]}
  def purpose(_provider, _purpose), do: :error

  def method_scope("gmail", :receive), do: {:ok, GmailScopes.read()}
  def method_scope("gmail", :send), do: {:ok, GmailScopes.send()}
  def method_scope("microsoft", :receive), do: {:ok, MicrosoftScopes.read()}
  def method_scope("microsoft", :send), do: {:ok, MicrosoftScopes.send()}
  def method_scope(_provider, _purpose), do: :error

  def approved?("gmail", scope), do: scope in [GmailScopes.read(), GmailScopes.send()]
  def approved?("microsoft", scope),
    do: scope in [MicrosoftScopes.read(), MicrosoftScopes.send(), MicrosoftScopes.offline()]
  def approved?(_provider, _scope), do: false
end
```

- [ ] **Step 5: Make OAuth start incremental for both providers**

In `OAuth`, replace provider-specific purpose and expansion clauses with the registry:

```elixir
defp required_scopes(provider, purpose) do
  case OAuthScopes.purpose(provider, purpose) do
    {:ok, scopes} -> {:ok, scopes}
    :error -> {:error, oauth_error(:unsupported_oauth_purpose,
      "OAuth purpose is not supported by provider")}
  end
end

defp identity_scopes(provider), do: OAuthScopes.identity(provider)

defp expanded_required_scopes(provider, mailbox_id, purpose_scopes) do
  existing_scopes =
    OAuthAuthorization
    |> where([authorization],
      authorization.account_id == ^mailbox_id and authorization.provider == ^provider)
    |> select([authorization], authorization.granted_scopes)
    |> Repo.one()
    |> List.wrap()
    |> List.flatten()
    |> Enum.filter(&OAuthScopes.approved?(provider, &1))

  normalize_scopes(existing_scopes ++ purpose_scopes)
end
```

Keep PKCE S256, state digest, exact redirect URI, Gmail offline parameters, and Microsoft's `response_mode=query` unchanged. Remove the stale module comment that describes completion as future work.

- [ ] **Step 6: Extract one provider-neutral authorization engine**

Move the existing file, rename the module to `Manifold.Connectors.OAuthAuthorizations`, and replace `@provider`, `@approved_scopes`, Gmail-only query clauses, and Gmail-only messages with an explicit `provider` argument or the locked authorization's provider. The completion head must be:

```elixir
def complete(provider, code, %Consumed{provider: provider} = consumed, adapter, config, opts)
    when provider in ["gmail", "microsoft"] do
  # Retain the existing exchange -> identity -> canonical address -> cursor -> persist pipeline.
end
```

The existing implementation body remains the single source of truth for:

- authorization/account row locking;
- canonical account address and provider-subject checks;
- sorted full-scope validation against `consumed.required_scopes`;
- retaining an existing encrypted refresh token when the response omits one;
- atomically rotating a replacement refresh token;
- optimistic-lock retry/error normalization;
- independent receive/send creation, enabling, disabling, disconnect, and final-reference cleanup;
- authorization-anchored events and sanitized telemetry.

Use `purpose == :receive` to call `adapter.initial_cursors/3`; send completion passes `[]` and never creates a sync job. `add_authorized_method/6` must lock a connected authorization, require the provider/purpose method scope, create or enable the method, and for receive obtain an access token, call `initial_cursors/3`, persist cursors, and enqueue one unique `SyncAccount` job. It must not contact the OAuth authorization endpoint.

Before code exchange, place `consumed.required_scopes` into `provider_opts[:required_scopes]`. Before refresh, place the locked authorization's complete `granted_scopes` into `provider_opts[:required_scopes]`. This ensures Microsoft code exchange and refresh both request the snapshotted union rather than the adapter's receive-only fallback.

Update reconnect messages through:

```elixir
defp reconnect_message("gmail"), do: "Gmail authorization must be reconnected"
defp reconnect_message("microsoft"), do: "Microsoft authorization must be reconnected"
```

Keep `gmail_authorizations_test.exs` pointed at the renamed engine with `"gmail"` passed explicitly; do not duplicate the engine for Microsoft.

- [ ] **Step 7: Route public completion and token checkout by stored provider**

Replace the split legacy/shared completion clauses in `Connectors.complete_authorization/4` with one shared path for both providers. For `checkout_oauth_access_token/2`, load only the authorization provider, resolve `adapter_config(provider)`, then call `OAuthAuthorizations.checkout_access_token/4`; the engine re-locks and validates the authorization before decrypting anything.

The completion path must pass the full scope snapshot explicitly:

```elixir
provider_opts =
  opts
  |> provider_opts()
  |> Keyword.put(:required_scopes, consumed.required_scopes)

OAuthAuthorizations.complete(
  provider,
  code,
  consumed,
  adapter,
  config,
  Keyword.put(opts, :provider_opts, provider_opts)
)
```

Rename the public send reconnect API:

```elixir
@spec mark_oauth_send_reconnect_required(Ecto.UUID.t(), String.t(), atom(), Keyword.t()) ::
        {:ok, :marked | :already_marked | :stale | :inactive, OAuthAuthorization.t()}
        | {:error, Error.t() | Ecto.Changeset.t()}
def mark_oauth_send_reconnect_required(method_id, expected_access_token, error_code, opts \\ []) do
  OAuthAuthorizations.mark_send_reconnect_required(
    method_id,
    expected_access_token,
    error_code,
    opts
  )
end
```

Delete the legacy Microsoft persistence path only after both providers use the shared engine.

- [ ] **Step 8: Run authorization tests**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs
```

Expected: all new Microsoft matrices and the full Gmail regression suite pass; no test observes more than one refresh request for concurrent callers.

- [ ] **Step 9: Commit the provider-neutral OAuth engine**

```sh
git add -- apps/manifold_connectors/lib/manifold/connectors/microsoft_scopes.ex \
  apps/manifold_connectors/lib/manifold/connectors/oauth_scopes.ex \
  apps/manifold_connectors/lib/manifold/connectors/oauth_authorizations.ex \
  apps/manifold_connectors/lib/manifold/connectors/oauth.ex \
  apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs \
  apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs
git commit -m "feat(connectors): generalize shared OAuth lifecycle"
```

### Task 5: Use shared Microsoft authorization for sync and send-method checkout

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex:1-430,1100-1219`
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex:404-527,812-890,1960-2130`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/view.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/provider/microsoft_graph.ex:119-172`
- Modify: `apps/manifold_connectors/test/manifold/connectors/sync_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs`
- Modify: `apps/manifold_data/test/manifold/config_test.exs`

- [ ] **Step 1: Write failing shared-sync and send-checkout tests**

Add tests proving:

```elixir
test "Microsoft sync checks out Mail.Read from shared authorization without a Credential row"
test "Microsoft send checkout requires Mail.Send and exact canonical sender"
test "Microsoft send checkout returns only a redacted short-lived token and base URL"
test "method changes after queue snapshot fail revalidation"
test "a revoked authorization prevents unsent work from checking out a token"
test "disconnecting Microsoft receive leaves send connected and vice versa"
test "the final Microsoft disconnect erases both token ciphertext fields"
test "polling remains unique for 300 seconds and creates no webhook job"
```

Use a secret sentinel in checkout tests and assert it appears only in `method.credential`, while `inspect(method)`, config, persisted method, event metadata, job args, and captured telemetry do not contain it.

- [ ] **Step 2: Add failing setup-state tests**

Define the redacted view result and cover every state:

```elixir
%Manifold.Connectors.View.OAuthMethodSetup{
  provider: "microsoft",
  purpose: :send,
  state: :connect | :upgrade | :add | :connected | :reconnect
}
```

Assert `:connect` with no authorization, `:upgrade` when required scope is absent, `:add` when the scope is already present but the direction has no live method, `:connected` for an enabled healthy method, and `:reconnect` when the shared authorization is reconnect-required.

- [ ] **Step 3: Run focused tests and confirm legacy credential routing**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_data/test/manifold/config_test.exs
```

Expected: Microsoft sync still looks for `Credential`, send checkout has no Microsoft clause, and setup-state APIs do not exist.

- [ ] **Step 4: Generalize receive token checkout and reconnect propagation**

In `Sync.auth_material/5`, match any OAuth-backed implemented receive method:

```elixir
defp auth_material(
       %ReceiveMethod{kind: provider, oauth_authorization_id: authorization_id},
       _adapter,
       _config,
       now,
       provider_opts
     )
     when provider in ["gmail", "microsoft"] and is_binary(authorization_id) do
  with {:ok, required_scope} <- OAuthScopes.method_scope(provider, :receive) do
    Connectors.checkout_oauth_access_token(authorization_id,
      now: now,
      required_scope: required_scope,
      provider_opts: provider_opts
    )
  end
end
```

Generalize reconnect error handling from `kind: "gmail"` to `kind in ["gmail", "microsoft"]`, keep expected-access-token stale fencing, and render a provider-safe reconnect message. Remove Microsoft from the legacy Credential refresh path. Do not change polling or cursor checkpoint order.

- [ ] **Step 5: Generalize OAuth send-method checkout**

Replace Gmail-specific send checkout and snapshot helpers with:

```elixir
defp checkout_oauth_send_method(
       %SendMethod{kind: provider, oauth_authorization_id: authorization_id} = snapshot,
       required_sender,
       opts
     )
     when provider in ["gmail", "microsoft"] and is_binary(authorization_id) do
  with {:ok, config} <- oauth_submission_config(provider),
       {:ok, required_scope} <- OAuthScopes.method_scope(provider, :send) do
    continuation = fn access_token ->
      with :ok <- after_oauth_checkout(opts) do
        lock_and_revalidate_oauth_method(snapshot, required_sender, access_token, config)
      end
    end

    checkout_oauth_access_token(authorization_id,
      opts
      |> Keyword.delete(:after_oauth_checkout)
      |> Keyword.put(:required_scope, required_scope)
      |> Keyword.put(:access_token_continuation, continuation)
    )
  end
end
```

`lock_and_revalidate_oauth_method/4` must compare kind, authorization ID, account ID, and email address against the snapshot under lock. `oauth_submission_config/1` returns only `:base_url` and safe test transport options from the configured provider. Dispatch `checkout_send_method/3` to this helper for Gmail and Microsoft; keep SMTP unchanged.

- [ ] **Step 6: Generalize disconnect/delete and expose setup state**

Route receive/send disconnect and receive deletion through `OAuthAuthorizations` whenever `oauth_authorization_id` is non-null and `kind` is Gmail or Microsoft. Add:

```elixir
@spec oauth_method_setup(Ecto.UUID.t(), String.t(), :receive | :send) ::
        {:ok, View.OAuthMethodSetup.t()} | {:error, Error.t()}
def oauth_method_setup(account_id, provider, purpose)

@spec add_authorized_oauth_method(Ecto.UUID.t(), String.t(), :receive | :send) ::
        {:ok, ReceiveMethod.t() | SendMethod.t()} | {:error, Error.t() | Ecto.Changeset.t()}
def add_authorized_oauth_method(account_id, provider, purpose)
```

The first API returns IDs/scopes neither directly nor indirectly; it returns only provider, purpose, and state. The second resolves adapter/config and delegates to `OAuthAuthorizations.add_authorized_method/6` so an already-complete grant does not start a redundant consent round trip.

- [ ] **Step 7: Make Microsoft token exchange honor the snapped union**

In `MicrosoftGraph.token_request/3`, derive the form scope from `opts[:required_scopes]` when present and fall back to configured scopes only for legacy callers:

```elixir
requested_scopes =
  opts
  |> Keyword.get(:required_scopes, String.split(Keyword.get(config, :scopes, @default_scopes)))
  |> Enum.uniq()
  |> Enum.sort()

form = [
  client_id: client_id,
  client_secret: client_secret,
  scope: Enum.join(requested_scopes, " ")
] ++ grant
```

Pass that list to token normalization so an omitted response `scope` retains the exact snapped union rather than silently falling back to receive-only defaults.

- [ ] **Step 8: Lock the tenant default and configuration semantics**

Add a config test that clears `MANIFOLD_MICROSOFT_TENANT`, evaluates runtime configuration, and asserts the authorization/token URLs contain `/organizations/`. Retain the existing startup failure for a partial client ID/secret pair and the unavailable-provider behavior for an absent pair. Add no environment variables.

- [ ] **Step 9: Run shared sync and checkout tests**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_data/test/manifold/config_test.exs
```

Expected: Microsoft receive and send share one refresh path, sender/snapshot/revocation fences pass, no legacy Microsoft credential is queried, and tenant default is `organizations`.

- [ ] **Step 10: Commit shared Microsoft runtime use**

```sh
git add -- apps/manifold_connectors/lib/manifold/connectors/sync.ex \
  apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_connectors/lib/manifold/connectors/view.ex \
  apps/manifold_connectors/lib/manifold/connectors/provider/microsoft_graph.ex \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_data/test/manifold/config_test.exs
git commit -m "feat(connectors): use shared Microsoft authorization"
```

### Task 6: Resolve Microsoft well-known folders and classify delta lanes by ID

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/provider.ex:1-150`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/provider/microsoft_graph.ex:1-430`
- Modify: `apps/manifold_connectors/test/manifold/connectors/provider/microsoft_graph_test.exs`

**Metadata contract:**

```elixir
%{
  "folder_mapping_version" => 1,
  "folder_kinds_by_id" => %{
    "graph-inbox-id" => "inbox",
    "graph-archive-id" => "archive",
    "graph-deleted-id" => "trash",
    "graph-sent-id" => "sent"
  }
}
```

Each active `folder:<id>` cursor stores `"folder_mapping_version" => 1` and its resolved `"folder_kind"`; unmapped visible folders use `"archive"`.

- [ ] **Step 1: Write failing Graph bootstrap tests**

Add Req.Test coverage that asserts four token-authenticated GETs to:

```text
/me/mailFolders/inbox?$select=id
/me/mailFolders/archive?$select=id
/me/mailFolders/deleteditems?$select=id
/me/mailFolders/sentitems?$select=id
```

Return localized `displayName` values and stable IDs. Assert `initial_cursors/3` contains the ID map above and does not use any display name. Use a barrier in the four Req.Test handlers to prove all lookups begin before any handler is released. Add separate cases for optional Archive `404`, required Inbox/Deleted/Sent `404`, `401`, `429` with Retry-After, and transport failure.

- [ ] **Step 2: Write failing folder-delta and reset tests**

Feed a folder delta containing localized Inbox/Sent display names and a custom folder. Assert discovered cursors classify only by ID, initial folder/message delta URLs include the explicit `$select` sets, and the Prefer header contains both immutable ID and `odata.maxpagesize=100`. Assert a cursor reset retains accepted history and marks mapping refresh required.

- [ ] **Step 3: Run the provider test and verify name-based behavior fails**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/provider/microsoft_graph_test.exs
```

Expected: FAIL because `initial_cursors/3` ignores its token, only creates `/mailFolders/delta`, and `graph_folder_kind/1` classifies English display names.

- [ ] **Step 4: Add the normalized provider mapping result**

In `provider.ex`, add:

```elixir
defmodule Manifold.Connectors.Provider.FolderMapping do
  @moduledoc false
  @enforce_keys [:version, :kinds_by_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: pos_integer(),
          kinds_by_id: %{required(String.t()) => "inbox" | "archive" | "sent" | "trash"}
        }
end
```

Add an optional callback:

```elixir
@callback resolve_folder_mapping(String.t(), Keyword.t(), Keyword.t()) ::
            {:ok, FolderMapping.t()} | {:error, Error.t()}
@optional_callbacks exchange_code: 5, refresh_token: 3, resolve_folder_mapping: 3
```

- [ ] **Step 5: Implement concurrent well-known resolution**

In `MicrosoftGraph`, set `@folder_mapping_version 1` and implement `resolve_folder_mapping/3`. Use `Task.async_stream/3` with `max_concurrency: 4`, `ordered: true`, and a bounded timeout to fetch the four independent well-known names. Each call must reuse `graph_request/5` so bearer auth, redirect policy, error normalization, and test transport remain centralized.

Archive `404` returns no map entry. A required-folder `404` returns a permanent `:required_folder_missing` provider error. Any duplicate/blank returned ID is an invalid response. All other errors retain their existing reconnect/throttle/transport class.

- [ ] **Step 6: Bootstrap mapping before creating cursors**

Implement `initial_cursors/3` as:

```elixir
def initial_cursors(access_token, config, opts) do
  with {:ok, base_url} <- fetch_config(config, :base_url),
       :ok <- validate_graph_url(base_url, base_url),
       {:ok, %FolderMapping{} = mapping} <- resolve_folder_mapping(access_token, config, opts) do
    {:ok, [
      %SyncCursor{
        scope: "folders",
        phase: "bootstrap",
        page_cursor: initial_folder_delta_url(base_url),
        metadata: mapping_metadata(mapping)
      }
    ]}
  end
end
```

Build only the initial URLs locally:

```elixir
folder fields:  id,displayName
message fields: id,parentFolderId,conversationId,receivedDateTime,isRead,flag
```

Continuation and delta links remain opaque Graph values after authority validation.

- [ ] **Step 7: Remove display-name semantics**

Pass the folder-discovery cursor metadata into `folder_cursor/3` and resolve:

```elixir
folder_kind = Map.get(kinds_by_id, id, "archive")
metadata = %{
  "folder_mapping_version" => @folder_mapping_version,
  "folder_kind" => folder_kind
}
```

Delete `graph_folder_kind/1`. Keep `displayName` as untrusted presentation input only; do not persist it as system semantics. When a folder or message cursor resets, preserve the cursor scope and generation behavior but add `"folder_mapping_refresh_required" => true` to metadata so Sync re-resolves before the next page.

- [ ] **Step 8: Run the Graph provider tests**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/provider/microsoft_graph_test.exs
```

Expected: all well-known, localized-name, Archive-optional, required-folder, bounded-page, immutable-ID, reset, pagination, and authority-validation tests pass.

- [ ] **Step 9: Commit locale-independent Graph mapping**

```sh
git add -- apps/manifold_connectors/lib/manifold/connectors/provider.ex \
  apps/manifold_connectors/lib/manifold/connectors/provider/microsoft_graph.ex \
  apps/manifold_connectors/test/manifold/connectors/provider/microsoft_graph_test.exs
git commit -m "feat(connectors): resolve Microsoft folder identities"
```

### Task 7: Reconcile upgraded Microsoft cursors and historical placement in place

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/microsoft_folder_mapping.ex`
- Create: `apps/manifold_connectors/lib/manifold/connectors/remote_state_jobs.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex:95-150,860-980`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth_authorizations.ex`
- Modify: `apps/manifold_connectors/test/manifold/connectors/sync_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs`

**Public internal interface:**

```elixir
MicrosoftFolderMapping.ensure_current(receive_method, selected_cursor, access_token,
  adapter, config, opts) ::
  {:ok, Manifold.Connectors.Schema.SyncCursor.t()} | {:error, Provider.Error.t() | Error.t()}

MicrosoftFolderMapping.invalidate(receive_method_id) :: :ok | {:error, Error.t()}
RemoteStateJobs.ensure(remote_message_id) :: Oban.Job.t()
```

- [ ] **Step 1: Write the failing upgraded-account repair test**

Create a Microsoft receive fixture with:

- a committed folders delta URL;
- a selected message cursor with its own committed delta URL;
- empty/stale mapping metadata;
- imported remote rows for localized Inbox, Deleted Items, Sent Items, and a custom folder, all historically stored as Archive;
- projected entries currently in Archive;
- raw object keys whose fetch counter starts at zero.

Run one Sync page with fake well-known-ID responses and assert:

```elixir
assert refreshed_folders.committed_cursor == original_folders_delta
assert refreshed_selected.committed_cursor == original_message_delta
assert refreshed_folders.metadata["folder_mapping_version"] == 1
assert Repo.get!(RemoteMessage, sent_remote.id).remote_folder_kind == "sent"
assert Repo.get!(RemoteMessage, inbox_remote.id).remote_folder_kind == "inbox"
assert Repo.get!(RemoteMessage, deleted_remote.id).remote_folder_kind == "trash"
assert Repo.get!(RemoteMessage, custom_remote.id).remote_folder_kind == "archive"
assert apply_remote_state_job_exists?(sent_remote.id)
assert raw_fetch_count() == 0
```

Run repair a second time and assert cursor positions remain byte-for-byte equal, no duplicate ApplyRemoteState jobs exist, and no remote row changes again.

- [ ] **Step 2: Add selected-lane and reconnect/reset tests**

Add cases proving a message lane selected before the folder-discovery lane still checks the stored discovery metadata; a reset flag forces re-resolution; and successful Microsoft reconnect invalidates mapping metadata without deleting or replacing cursor URLs.

- [ ] **Step 3: Run Sync tests and confirm metadata is never repaired**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs
```

Expected: FAIL because discovered cursors use `on_conflict: :nothing` and no upgraded-state reconciliation exists.

- [ ] **Step 4: Implement the mapping coordinator**

`ensure_current/6` must:

1. Read the stored `scope == "folders"` cursor regardless of the selected lane.
2. Return the selected cursor unchanged when discovery metadata is version 1 and no cursor carries `folder_mapping_refresh_required`.
3. Call `adapter.resolve_folder_mapping/3` outside the database transaction when stale.
4. In one transaction, lock the receive method and all its cursors, recheck staleness, and update metadata only; never replace `phase`, `bootstrap_cursor`, `page_cursor`, `committed_cursor`, `generation`, or `last_completed_at`.
5. Set every `folder:<id>` cursor's `folder_kind` from the map or `archive`, set version 1, and remove the refresh flag.
6. Lock remote rows for the receive method, derive kind from `remote_folder_id`, and update only rows whose stored kind differs.
7. Call `RemoteStateJobs.ensure/1` for each changed imported row with an inbound delivery.
8. Re-read and return the selected cursor by ID.

Use the same safe telemetry metadata already accepted elsewhere: provider, internal account/method/cursor IDs, outcome, changed-cursor count, changed-message count, and normalized error code only.

Move Sync's current `ensure_remote_state_job/1` query/insert body unchanged into `Manifold.Connectors.RemoteStateJobs.ensure/1`, and update normal Sync ingestion to call that module too. This preserves one implementation of the active-job lookup plus `ApplyRemoteState.new/1` insertion and lets mapping repair reuse the same uniqueness boundary without a Sync-to-mapping module cycle.

- [ ] **Step 5: Invoke reconciliation before every Microsoft page**

After shared token checkout and before `sync_page/5`, add:

```elixir
with {:ok, cursor} <-
       maybe_reconcile_folder_mapping(account, cursor, auth, adapter, config, provider_opts(opts)),
     {:ok, %Page{} = page} <- sync_page(adapter, auth, cursor, config, provider_opts(opts)) do
  # Existing import-before-checkpoint pipeline remains unchanged.
end
```

For non-Microsoft providers, return the selected cursor unchanged. If mapping resolution fails, route the normalized provider error through the existing sync error/reconnect/throttle behavior before any cursor advancement.

- [ ] **Step 6: Invalidate mapping after reconnect without resetting cursors**

When Microsoft completion reconnects an existing receive method, call `MicrosoftFolderMapping.invalidate/1` in the same lifecycle transaction. It must remove only `folder_mapping_version` and set `folder_mapping_refresh_required`; it must not call `initial_cursors/3`, delete cursors, or enqueue raw refetch work.

- [ ] **Step 7: Run repair and receive regression tests**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_connectors/test/manifold/connectors/provider/microsoft_graph_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors_test.exs
```

Expected: upgraded cursor URLs remain unchanged, historical local placement is corrected idempotently, no raw MIME is fetched by repair, normal delta import/replay/reset tests remain green, and reconnect triggers one mapping refresh.

- [ ] **Step 8: Commit in-place Microsoft folder repair**

```sh
git add -- apps/manifold_connectors/lib/manifold/connectors/microsoft_folder_mapping.ex \
  apps/manifold_connectors/lib/manifold/connectors/remote_state_jobs.ex \
  apps/manifold_connectors/lib/manifold/connectors/sync.ex \
  apps/manifold_connectors/lib/manifold/connectors/oauth_authorizations.ex \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs
git commit -m "fix(connectors): reconcile Microsoft folder mappings"
```

### Task 8: Persist immutable provider MIME payloads at queue time

**Files:**
- Create: `apps/manifold_data/priv/repo/migrations/20260812000300_add_microsoft_provider_payloads.exs`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/schema/provider_submission.ex:1-105`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/rfc_message.ex:1-370`
- Modify: `apps/manifold_outbound/lib/manifold/outbound.ex:258-388,698-755`
- Modify: `apps/manifold_outbound/test/manifold/outbound/rfc_message_test.exs`
- Modify: `apps/manifold_outbound/test/manifold/outbound_test.exs`
- Modify: `apps/manifold_outbound/test/manifold/outbound/submission_test.exs`

**Snapshot contract:** Every newly queued Gmail, SMTP, or Microsoft provider submission stores `send_method_id`, `provider`, `canonical_sender_address`, deterministic `provider_rfc_message_id`, `render_version = 1`, exact binary `request_payload`, and lowercase SHA-256. Existing method-backed rows remain readable with nil payload/version for the one-time verified compatibility path added in Task 10. Existing Resend rows keep their provider and idempotency window.

- [ ] **Step 1: Write failing schema and redaction tests**

Add to `submission_test.exs`:

```elixir
test "provider submission stores immutable payload fields and redacts MIME inspection" do
  sentinel = "Bcc: private-recipient@example.test\r\n\r\nprivate-body\r\n"

  changeset =
    ProviderSubmission.changeset(%ProviderSubmission{}, %{
      outbound_message_id: Ecto.UUID.generate(),
      send_method_id: Ecto.UUID.generate(),
      provider: "microsoft",
      canonical_sender_address: "sender@example.test",
      idempotency_key: Ecto.UUID.generate(),
      request_sha256: sha256(sentinel),
      request_payload: sentinel,
      render_version: 1,
      provider_rfc_message_id: "<message@manifold.local>",
      state: "pending",
      attempt_count: 0
    })

  assert changeset.valid?
  submission = Ecto.Changeset.apply_changes(changeset)
  refute inspect(submission) =~ sentinel
  refute inspect(submission) =~ "private-recipient"
end

test "new method-backed snapshots reject missing payload and nonpositive render version" do
  assert %{request_payload: [_ | _]} = errors_on(method_submission_changeset(request_payload: nil))
  assert %{render_version: [_ | _]} = errors_on(method_submission_changeset(render_version: 0))
end

defp method_submission_changeset(overrides) do
  attrs = %{
    outbound_message_id: Ecto.UUID.generate(),
    send_method_id: Ecto.UUID.generate(),
    provider: "microsoft",
    canonical_sender_address: "sender@example.test",
    idempotency_key: Ecto.UUID.generate(),
    request_payload: "From: sender@example.test\r\n\r\nBody\r\n",
    render_version: 1,
    provider_rfc_message_id: "<message@manifold.local>",
    state: "pending",
    attempt_count: 0
  }

  attrs = Map.merge(attrs, Map.new(overrides))
  attrs = Map.put(attrs, :request_sha256, sha256(attrs.request_payload || ""))
  ProviderSubmission.changeset(%ProviderSubmission{}, attrs)
end
```

- [ ] **Step 2: Write failing queue-time render tests**

Queue through a Microsoft method and assert:

```elixir
submission = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)
assert submission.provider == "microsoft"
assert submission.send_method_id == microsoft_method.id
assert submission.canonical_sender_address == queued.canonical_sender_address
assert submission.render_version == 1
assert is_binary(submission.request_payload)
assert sha256(submission.request_payload) == submission.request_sha256
assert submission.request_payload =~ "Bcc: blind@example.net\r\n"
assert submission.provider_rfc_message_id == "<#{queued.id}@manifold.local>"

assert [job] = jobs_for(queued.id)
assert job.args == %{"outbound_message_id" => queued.id}
refute inspect(job.args) =~ "blind@example.net"
```

Add a renderer test proving Microsoft has byte-identical To/Cc/Bcc, subject, date, Message-ID, reply headers, UTF-8 encoding, quoted-printable body, and CRLF behavior to Gmail for the same envelope. Retain SMTP's omission of the Bcc header.

- [ ] **Step 3: Run tests and verify the bytes are discarded today**

```sh
devenv shell -- mix test \
  apps/manifold_outbound/test/manifold/outbound/rfc_message_test.exs \
  apps/manifold_outbound/test/manifold/outbound_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs
```

Expected: FAIL because Microsoft is not a renderer/provider kind and queueing stores only the hash and RFC Message-ID.

- [ ] **Step 4: Add the outbound payload migration**

Implement:

```elixir
defmodule Manifold.Repo.Migrations.AddMicrosoftProviderPayloads do
  use Ecto.Migration

  def up do
    alter table(:provider_submissions) do
      add(:canonical_sender_address, :text)
      add(:render_version, :integer)
      add(:request_payload, :binary)
    end

    execute("""
    UPDATE provider_submissions AS submission
    SET canonical_sender_address = outbound.canonical_sender_address
    FROM outbound_messages AS outbound
    WHERE outbound.id = submission.outbound_message_id
    """)

    execute("ALTER TABLE provider_submissions ALTER COLUMN canonical_sender_address SET NOT NULL")

    create(
      constraint(:provider_submissions, :provider_submissions_render_version_positive,
        check: "render_version IS NULL OR render_version > 0"
      )
    )

    execute("""
    ALTER TABLE provider_submissions
    DROP CONSTRAINT IF EXISTS provider_submissions_send_method_provider_fkey
    """)
    drop(constraint(:provider_submissions, :provider_submissions_method_shape_valid))
    drop(constraint(:provider_submissions, :provider_submissions_provider_valid))

    create(constraint(:provider_submissions, :provider_submissions_provider_valid,
      check: "provider IN ('resend', 'gmail', 'smtp', 'microsoft')"))

    create(constraint(:provider_submissions, :provider_submissions_method_shape_valid,
      check: """
      (provider = 'resend' AND send_method_id IS NULL AND idempotency_expires_at IS NOT NULL)
      OR
      (provider IN ('gmail', 'smtp', 'microsoft') AND send_method_id IS NOT NULL
       AND idempotency_expires_at IS NULL)
      """))

    execute("""
    ALTER TABLE provider_submissions
    ADD CONSTRAINT provider_submissions_send_method_provider_fkey
    FOREIGN KEY (send_method_id, provider)
    REFERENCES connector_send_methods (id, kind)
    ON DELETE RESTRICT
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM provider_submissions WHERE provider = 'microsoft') THEN
        RAISE EXCEPTION 'cannot rollback Microsoft provider payloads while Microsoft submissions exist';
      END IF;
    END
    $$
    """)

    execute("ALTER TABLE provider_submissions DROP CONSTRAINT IF EXISTS provider_submissions_send_method_provider_fkey")
    drop(constraint(:provider_submissions, :provider_submissions_method_shape_valid))
    drop(constraint(:provider_submissions, :provider_submissions_provider_valid))
    drop(constraint(:provider_submissions, :provider_submissions_render_version_positive))

    create(constraint(:provider_submissions, :provider_submissions_provider_valid,
      check: "provider IN ('resend', 'gmail', 'smtp')"))
    create(constraint(:provider_submissions, :provider_submissions_method_shape_valid,
      check: """
      (provider = 'resend' AND send_method_id IS NULL AND idempotency_expires_at IS NOT NULL)
      OR
      (provider IN ('gmail', 'smtp') AND send_method_id IS NOT NULL
       AND idempotency_expires_at IS NULL)
      """))
    execute("""
    ALTER TABLE provider_submissions
    ADD CONSTRAINT provider_submissions_send_method_provider_fkey
    FOREIGN KEY (send_method_id, provider)
    REFERENCES connector_send_methods (id, kind)
    ON DELETE RESTRICT
    """)

    alter table(:provider_submissions) do
      remove(:request_payload)
      remove(:render_version)
      remove(:canonical_sender_address)
    end
  end
end
```

- [ ] **Step 5: Extend the provider-submission schema**

Add the fields and protect inspection:

```elixir
@derive {Inspect, except: [:request_payload]}
schema "provider_submissions" do
  # existing fields
  field(:canonical_sender_address, :string)
  field(:render_version, :integer)
  field(:request_payload, :binary)
end
```

Cast all three, validate canonical sender for every row, accept `~w(resend gmail smtp microsoft)`, and for `provider in ["gmail", "smtp", "microsoft"]` require `send_method_id`, `request_payload`, `render_version`, and `provider_rfc_message_id` while requiring nil `idempotency_expires_at`. Validate `render_version > 0` and attach the named database check. The compatibility loader in Task 10 reads old rows directly and fills missing fields under lock; it does not pass a legacy nil payload through the new insertion changeset.

- [ ] **Step 6: Render Microsoft MIME and retain exact bytes**

Update `RfcMessage.provider/1` to accept `:microsoft`, and implement:

```elixir
defp maybe_add_bcc(headers, provider, values) when provider in [:gmail, :microsoft],
  do: add_address_header(headers, "Bcc", values)
defp maybe_add_bcc(headers, :smtp, _values), do: headers
```

In `Outbound.render_submission/4`, add `"microsoft" -> :microsoft` and return:

```elixir
%{
  send_method_id: method.id,
  provider: method.kind,
  provider_rfc_message_id: provider_rfc_message_id,
  idempotency_key: idempotency_key,
  canonical_sender_address: message.canonical_sender_address,
  render_version: 1,
  request_payload: raw_message,
  request_sha256: sha256(raw_message)
}
```

Persist every field in `submission_changeset/2` inside the existing queue transaction. Do not duplicate payload in the event or job args.

- [ ] **Step 7: Run migration, renderer, queue, and constraint tests**

```sh
devenv shell -- mix ecto.migrate
devenv shell -- mix test \
  apps/manifold_outbound/test/manifold/outbound/rfc_message_test.exs \
  apps/manifold_outbound/test/manifold/outbound_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs
```

Expected: new method-backed rows persist redacted exact MIME bytes and a positive version; Microsoft Bcc is present; legacy Resend fixtures remain valid.

- [ ] **Step 8: Commit immutable outbound payloads**

```sh
git add -- apps/manifold_data/priv/repo/migrations/20260812000300_add_microsoft_provider_payloads.exs \
  apps/manifold_outbound/lib/manifold/outbound/schema/provider_submission.ex \
  apps/manifold_outbound/lib/manifold/outbound/rfc_message.ex \
  apps/manifold_outbound/lib/manifold/outbound.ex \
  apps/manifold_outbound/test/manifold/outbound/rfc_message_test.exs \
  apps/manifold_outbound/test/manifold/outbound_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs
git commit -m "feat(outbound): persist immutable provider MIME"
```

### Task 9: Implement the Microsoft Graph MIME submission adapter

**Files:**
- Modify: `apps/manifold_outbound/lib/manifold/outbound/provider.ex:1-100`
- Create: `apps/manifold_outbound/lib/manifold/outbound/provider/microsoft_graph.ex`
- Create: `apps/manifold_outbound/test/manifold/outbound/provider/microsoft_graph_test.exs`

**Provider contract:** `POST <base_url>/me/sendMail`, bearer authorization, `Content-Type: text/plain`, body `Base.encode64(exact_mime)`, `retry: false`, `redirect: false`, and only HTTP 202 is accepted. Request IDs are bounded diagnostic metadata, never provider message IDs or idempotency keys.

- [ ] **Step 1: Write the exact request/success test**

Use a `Provider.Request` containing a MIME sentinel and assert:

```elixir
Req.Test.expect(MicrosoftGraph, fn conn ->
  assert conn.method == "POST"
  assert conn.request_path == "/me/sendMail"
  assert conn.query_string == ""
  assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@access_token}"]
  assert Plug.Conn.get_req_header(conn, "content-type") == ["text/plain"]
  {:ok, body, conn} = Plug.Conn.read_body(conn)
  assert body == Base.encode64(@raw_message)

  conn
  |> Plug.Conn.put_resp_header("request-id", "graph-request-1")
  |> Plug.Conn.put_resp_header("client-request-id", "graph-client-1")
  |> Plug.Conn.send_resp(202, "")
end)

assert {:ok, %Provider.Submission{
  provider_message_id: nil,
  metadata: %{
    "request_id" => "graph-request-1",
    "client_request_id" => "graph-client-1"
  }
}} = MicrosoftGraph.submit(@config, @request)
```

- [ ] **Step 2: Write the full classification matrix**

Add separate assertions for:

```text
429 + numeric/date Retry-After             -> transient/rate_limited
tagged pre-transmission Req.TransportError -> transient/transport_error
500, 502, 503, 504                         -> uncertain/acceptance_unknown
ordinary or post-transmission transport    -> uncertain/acceptance_unknown
2xx other than 202                         -> uncertain/invalid_response
401 or InvalidAuthenticationToken          -> permanent/reconnect_required
403 Authorization_RequestDenied or explicit insufficient_scope
                                             -> permanent/insufficient_scope
403 ErrorAccessDenied or tenant policy      -> permanent/policy_rejected
400 invalid MIME/recipient/parameter        -> permanent/request_rejected
other definite 4xx                          -> permanent/request_rejected
missing access token                        -> permanent/provider_not_configured
```

For every response, include secret strings in Graph's body and assert neither returned `Provider.Error` nor captured logs/telemetry contains them. Include hostile Req options for URL, method, auth, body, headers, retry, and redirect and prove the adapter ignores them; include a redirect response and prove the bearer token is not sent to the redirected host.

- [ ] **Step 3: Run the new provider test and verify the adapter is absent**

```sh
devenv shell -- mix test apps/manifold_outbound/test/manifold/outbound/provider/microsoft_graph_test.exs
```

Expected: FAIL because the module and registry entry do not exist.

- [ ] **Step 4: Permit a nullable provider result ID**

Keep `provider_message_id` in `@enforce_keys` so every adapter makes an explicit choice, but change the type:

```elixir
@type t :: %__MODULE__{
        provider_message_id: String.t() | nil,
        metadata: map()
      }
```

Register:

```elixir
def adapter("microsoft"), do: {:ok, Manifold.Outbound.Provider.MicrosoftGraph}
```

- [ ] **Step 5: Implement the adapter with a closed Req option set**

Create `Manifold.Outbound.Provider.MicrosoftGraph` using only `:plug`, `:receive_timeout`, `:pool_timeout`, and a nested connect timeout from caller Req options. Construct method, URL, bearer auth, content type, Base64 body, retry, and redirect after filtering so callers cannot override request semantics.

On 202, call a helper that reads only `request-id` and `client-request-id`, accepts one value matching `~r/\A[A-Za-z0-9._:-]{1,128}\z/`, maps keys to `request_id`/`client_request_id`, and drops all other/ambiguous values. Never retain headers or body wholesale.

Implement explicit response clauses in the matrix order from Step 2. The only transient transport clause is:

```elixir
defp classify_transport_failure(%Req.TransportError{
       reason: {:manifold_transport_phase, :pre_transmission, _reason}
     }) do
  error(:transient, "transport_error", "Microsoft request could not be transmitted")
end

defp classify_transport_failure(_unknown_or_post_dispatch) do
  error(:uncertain, "acceptance_unknown", "Microsoft may have accepted the message")
end
```

Do not reuse receive-side Graph error classification because receive safely retries errors that outbound must classify as uncertain.

- [ ] **Step 6: Run the provider tests**

```sh
devenv shell -- mix test \
  apps/manifold_outbound/test/manifold/outbound/provider/microsoft_graph_test.exs \
  apps/manifold_outbound/test/manifold/outbound/provider/gmail_test.exs \
  apps/manifold_outbound/test/manifold/outbound/provider/smtp_test.exs
```

Expected: Microsoft request and classification matrix passes; Gmail and SMTP adapters remain unchanged.

- [ ] **Step 7: Commit the Microsoft Graph adapter**

```sh
git add -- apps/manifold_outbound/lib/manifold/outbound/provider.ex \
  apps/manifold_outbound/lib/manifold/outbound/provider/microsoft_graph.ex \
  apps/manifold_outbound/test/manifold/outbound/provider/microsoft_graph_test.exs
git commit -m "feat(outbound): submit MIME through Microsoft Graph"
```

### Task 10: Dispatch Microsoft snapshots with identical-byte retry and uncertainty fences

**Files:**
- Modify: `apps/manifold_outbound/lib/manifold/outbound/submission.ex:180-800`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/jobs/submit_outbound.ex:1-55`
- Modify: `apps/manifold_outbound/test/manifold/outbound/submission_test.exs`
- Modify: `apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs`
- Modify: `apps/manifold_outbound/test/manifold/outbound_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/sync_test.exs`

- [ ] **Step 1: Write failing immutable-retry and dispatch tests**

Queue a Microsoft message, capture its persisted payload, mutate every editable source field and switch the account's enabled method, force an explicit 429, and then retry. Assert both provider calls receive the original persisted bytes/hash and the originally snapshotted method ID. Assert credential checkout occurs only after payload/hash/sender validation.

Add a pre-existing Gmail/SMTP compatibility fixture with nil payload/version. Its first locked attempt must re-render once, verify the stored hash, persist payload/version, and dispatch. A fixture whose current render does not match the stored hash must fail `request_integrity_failed` without credential checkout or provider call. A Microsoft row with nil payload must fail integrity; it cannot be legacy.

- [ ] **Step 2: Write failing acceptance and uncertainty tests**

Cover:

```elixir
test "bodyless Microsoft 202 accepts with nil provider ID and skips provider-event reconciliation"
test "request correlation metadata is retained separately from provider IDs"
test "Microsoft 429 returns queued/pending and schedules the identical-byte retry"
test "Microsoft 5xx atomically becomes submission_uncertain and worker returns ok"
test "unknown transport loss becomes uncertain and never receives another provider call"
test "interrupted Microsoft submitting state becomes uncertain before dispatch"
test "revocation marks shared authorization and both methods reconnect_required"
test "a stale rejected token retries with the newly rotated authorization"
test "new Microsoft queueing never falls back to Resend"
test "legacy queued Resend still finishes through its original provider"
```

After uncertainty, assert outbound message state, submission state, one `submission_uncertain` event, completed/cancelled job behavior, and no available/scheduled/retryable SubmitOutbound job.

- [ ] **Step 3: Write the Sent convergence boundary test**

For a send-only Microsoft method, accept a message and assert no projected Sent mailbox entry is created. Then add Microsoft Receive, feed one Graph Sent Items delta/raw-MIME item with the provider's immutable message ID, run the existing import/apply pipeline twice, and assert exactly one inbound delivery/mapping/projected entry exists in the Sent folder while the outbound acceptance record remains separate.

- [ ] **Step 4: Run focused tests and verify missing dispatch/fences**

```sh
devenv shell -- mix test \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs \
  apps/manifold_outbound/test/manifold/outbound_test.exs \
  apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs
```

Expected: FAIL because dispatch only accepts Gmail/SMTP, re-renders each attempt, requires a provider ID during reconciliation, and omits Microsoft from the interrupted non-idempotent fence.

- [ ] **Step 5: Load and verify payload before credential checkout**

In the locked preparation transaction, add:

```elixir
defp ensure_request_payload(message, submission, recipients) do
  cond do
    is_binary(submission.request_payload) and
        sha256(submission.request_payload) == submission.request_sha256 and
        submission.canonical_sender_address == message.canonical_sender_address ->
      {:ok, submission}

    submission.provider in ["gmail", "smtp"] and
        is_nil(submission.request_payload) and is_nil(submission.render_version) ->
      backfill_legacy_payload(message, submission, recipients)

    true ->
      {:error, provider_error("request_integrity_failed")}
  end
end
```

`backfill_legacy_payload/3` uses the stored provider, RFC Message-ID, and queued timestamp, compares SHA-256, and persists exact bytes plus render version 1 under the existing row lock. Call this before transitioning to `submitting` so integrity failure neither increments attempts nor exposes credentials. Build `Provider.Request.raw_message` directly from the verified persisted payload; remove normal retry-time rendering.

- [ ] **Step 6: Add Microsoft to every non-idempotent dispatch fence**

Include Microsoft in:

```elixir
provider in ["gmail", "smtp", "microsoft"]
```

for interrupted-submitting uncertainty and method-backed dispatch. After constructing the verified request, call `Connectors.checkout_send_method/3`, require the exact method provider, resolve the provider adapter, and build Microsoft config from the short-lived OAuth credential just as Gmail does. Keep Resend's legacy branch separate.

- [ ] **Step 7: Generalize reconnect lifecycle handling**

Rename `maybe_mark_gmail_reconnect/3` to `maybe_mark_oauth_reconnect/3`. For Gmail or Microsoft methods whose provider returns `reconnect_required` or `insufficient_scope`, call `Connectors.mark_oauth_send_reconnect_required/4` with the rejected access-token snapshot. A stale outcome converts the provider error to transient `stale_access_token`; marked/already/inactive retain the original permanent result; persistence failure returns safe `oauth_reconnect_lifecycle_failed`.

- [ ] **Step 8: Persist bodyless acceptance safely**

Keep `provider_message_id` nullable in the changeset update and event. Replace unconditional reconciliation with:

```elixir
case provider_submission.provider_message_id do
  id when is_binary(id) and id != "" ->
    ProviderEvents.reconcile_pending(submission.provider, id, message.id, now)

  nil ->
    :ok
end
```

Persist only sanitized correlation metadata from the adapter. Do not derive a provider ID from Graph request IDs and do not use `ProviderEvents` to link Microsoft Sent Items.

- [ ] **Step 9: Preserve worker retry boundaries**

Retain `SubmitOutbound` retry only for `%Provider.Error{class: :transient}`. Confirm `%Error{reason: :submission_uncertain}` and permanent provider errors return `:ok`, while 429 honors nonnegative Retry-After. Do not add a manual resend action.

- [ ] **Step 10: Run outbound and convergence tests**

```sh
devenv shell -- mix test \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs \
  apps/manifold_outbound/test/manifold/outbound_test.exs \
  apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs
```

Expected: retries submit byte-identical payloads; 202 accepts with nil provider ID; 5xx/ambiguous/interrupted cases are terminal uncertainty; 429/pre-dispatch errors are the only retry cases; Sent convergence occurs only through receive sync.

- [ ] **Step 11: Commit Microsoft dispatch and uncertainty semantics**

```sh
git add -- apps/manifold_outbound/lib/manifold/outbound/submission.ex \
  apps/manifold_outbound/lib/manifold/outbound/jobs/submit_outbound.ex \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs \
  apps/manifold_outbound/test/manifold/outbound_test.exs \
  apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs
git commit -m "feat(outbound): dispatch Microsoft submissions safely"
```

### Task 11: Add Microsoft receive/send setup, incremental add, and shared reconnect UI

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/receive_method_new.ex:1-430`
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/send_method_new.ex:1-330`
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/show.ex:1-380`
- Modify: `apps/manifold_web/test/manifold_web/account_live_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`

- [ ] **Step 1: Write failing provider-availability and setup-state tests**

Add LiveView tests proving:

```elixir
test "Microsoft 365 send remains visible and disabled when provider config is absent"
test "new Microsoft send shows Connect Microsoft"
test "receive-only Microsoft shows Upgrade Microsoft access for send"
test "a complete grant without a send method shows Add Microsoft Send"
test "an enabled method shows Connected"
test "reconnect explains that both receive and send are paused"
test "send-only authorization can add or upgrade Microsoft Receive symmetrically"
```

For the unavailable case assert the button `#send-method-microsoft` exists, is disabled, and contains `Provider not configured`. For every state, assert no authorization ID, scopes, token value, or provider error body renders into HTML.

- [ ] **Step 2: Write failing OAuth/account-isolation tests**

In `external_accounts_web_test.exs`, assert the Microsoft Send link uses exactly the selected account ID and `purpose=send`, callback completion returns to that account, and a second account cannot consume/rebind the first account's transaction. Cover safe flash text for subject mismatch, canonical-address mismatch, missing scope, expired state, and provider failure without echoing the raw Microsoft error.

- [ ] **Step 3: Run the Web tests and verify Microsoft send is absent**

```sh
devenv shell -- mix test \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: FAIL because the send picker has only Gmail/SMTP and account-show upgrade/reconnect helpers are Gmail-specific.

- [ ] **Step 4: Add Microsoft to the send picker**

Add this card beside Gmail:

```heex
<button
  id="send-method-microsoft"
  type="button"
  class="add-account-choice"
  phx-click="choose-kind"
  phx-value-kind="microsoft"
  disabled={"microsoft" not in @configured_providers}
>
  <.dm_mdi name="microsoft" />
  <span>
    <strong>Microsoft 365</strong>
    <small>
      {if "microsoft" in @configured_providers,
        do: "Send through Microsoft Graph",
        else: "Provider not configured"}
    </small>
  </span>
</button>
```

On selection, load `Connectors.oauth_method_setup(account.id, "microsoft", :send)`. Render the confirmation heading/action from the closed state map:

```elixir
%{
  connect: {"Connect Microsoft", "Continue with Microsoft"},
  upgrade: {"Upgrade Microsoft access", "Continue with Microsoft"},
  add: {"Add Microsoft Send", "Add Microsoft Send"},
  connected: {"Microsoft Send connected", "Connected"},
  reconnect: {"Reconnect Microsoft", "Reconnect Microsoft"}
}
```

For `:connect`, `:upgrade`, and `:reconnect`, use `/connectors/microsoft/start?account_id=<id>&purpose=send`. For `:add`, handle a LiveView event that calls `Connectors.add_authorized_oauth_method/3` and navigates back on success. For `:connected`, disable the action. Do not expose granted scopes to the template.

- [ ] **Step 5: Make receive setup symmetric**

When Gmail/Microsoft is chosen in `ReceiveMethodNew`, load setup state for `:receive`. If Microsoft state is `:add`, call `Connectors.add_authorized_oauth_method(account.id, "microsoft", :receive)`; this creates initial well-known mapping/cursors and the unique sync job through the connectors boundary. Otherwise use the purpose-correct OAuth link. Keep the existing unconfigured button behavior.

- [ ] **Step 6: Generalize account-show labels and reconnect actions**

Add `send_kind_label("microsoft")`, then replace Gmail-only helpers with provider-aware helpers over `~w(gmail microsoft)`. Render at most one reconnect action per provider. Microsoft copy must be:

```text
Reconnect the shared Microsoft authorization; both receive and send are paused.
```

If a healthy Microsoft authorization has receive but no send, show `Upgrade Microsoft access` linking to `purpose=send`. Disconnect buttons remain direction-specific and retain the other healthy method.

- [ ] **Step 7: Run settings/OAuth Web tests**

```sh
devenv shell -- mix test \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: all Microsoft configured/unconfigured, connect/add/upgrade/connected/reconnect, account-isolation, and safe-error tests pass; Gmail/SMTP/IMAP/EAS setup regressions remain green.

- [ ] **Step 8: Commit Microsoft settings workflows**

```sh
git add -- apps/manifold_web/lib/manifold_web/live/account_live/receive_method_new.ex \
  apps/manifold_web/lib/manifold_web/live/account_live/send_method_new.ex \
  apps/manifold_web/lib/manifold_web/live/account_live/show.ex \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
git commit -m "feat(web): add Microsoft mail method setup"
```

### Task 12: Split projected Sent from outbound Send activity and preserve old URLs

**Files:**
- Modify: `apps/manifold_outbound/lib/manifold/outbound.ex:192-256,577-630`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/view.ex:64-130`
- Modify: `apps/manifold_outbound/test/manifold/outbound_test.exs`
- Modify: `apps/manifold_web/lib/manifold_web/router.ex:20-45`
- Create: `apps/manifold_web/lib/manifold_web/controllers/sent_redirect_controller.ex`
- Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex:1-1480`
- Modify: `apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/mail_live_test.exs`
- Create: `apps/manifold_web/test/manifold_web/sent_redirect_controller_test.exs`

**Route contract:**

```text
/mail/:mailbox_id/send-activity                         outbound lifecycle list
/mail/:mailbox_id/send-activity/:outbound_message_id    outbound lifecycle detail
/mail/:mailbox_id/sent                                  redirect to projected Sent folder
/mail/:mailbox_id/sent/:outbound_message_id             redirect to Send activity detail
```

- [ ] **Step 1: Rename outbound context tests before implementation**

Change tests to call:

```elixir
assert [%View.SendActivitySummary{} = item] = Outbound.list_send_activity(mailbox.id)
assert {:ok, %View.SendActivityDetail{} = detail} =
         Outbound.get_send_activity(mailbox.id, item.id)
assert {:error, %Error{reason: :send_activity_not_found}} =
         Outbound.get_send_activity(other_mailbox.id, item.id)
```

Keep lifecycle semantics unchanged: queued, accepted, failed, and uncertain non-draft outbound rows are all activity records.

- [ ] **Step 2: Write failing route/navigation tests**

Add tests that:

- queueing redirects to `/send-activity/:id`;
- the Send activity list/detail renders outbound status immediately;
- the generic folder loop renders one projected `Sent` link and no second Sent label;
- selecting that link renders projected conversations from the Sent folder, not outbound records;
- `/sent` redirects to `/folders/<sent-folder-id>`;
- `/sent/<outbound-id>` redirects to `/send-activity/<outbound-id>` with the same mailbox/message IDs;
- a bad mailbox ID or unavailable Sent folder redirects safely to `/` with an error flash;
- a send-only Microsoft acceptance leaves projected Sent empty while Send activity shows accepted.

- [ ] **Step 3: Run focused tests and verify the semantic collision**

```sh
devenv shell -- mix test \
  apps/manifold_outbound/test/manifold/outbound_test.exs \
  apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs \
  apps/manifold_web/test/manifold_web/mail_live_test.exs \
  apps/manifold_web/test/manifold_web/sent_redirect_controller_test.exs
```

Expected: FAIL because outbound APIs/views/routes are named Sent and the hard-coded outbound Sent link collides with the new projected Sent folder.

- [ ] **Step 4: Rename outbound lifecycle APIs and structs**

Rename without changing queries:

```elixir
list_sent/1       -> list_send_activity/1
get_sent/2        -> get_send_activity/2
sent_detail_view  -> send_activity_detail_view
View.SentSummary  -> View.SendActivitySummary
View.SentDetail   -> View.SendActivityDetail
:sent_not_found   -> :send_activity_not_found
```

Update all scoped tests/callers; do not retain ambiguous `list_sent/1` wrappers.

- [ ] **Step 5: Install new LiveView routes and compatibility redirects**

In `router.ex`, add controller routes before `live_session` and replace outbound Sent LiveViews:

```elixir
get("/mail/:mailbox_id/sent", SentRedirectController, :index)
get("/mail/:mailbox_id/sent/:outbound_message_id", SentRedirectController, :show)

live("/mail/:mailbox_id/send-activity", MailLive.Index, :send_activity)
live(
  "/mail/:mailbox_id/send-activity/:outbound_message_id",
  MailLive.Index,
  :send_activity_detail
)
```

Implement the controller:

```elixir
defmodule ManifoldWeb.SentRedirectController do
  use ManifoldWeb, :controller

  alias Manifold.Mail

  def index(conn, %{"mailbox_id" => mailbox_id_param}) do
    with {:ok, mailbox_id} <- Ecto.UUID.cast(mailbox_id_param),
         {:ok, folders} <- Mail.list_folders(mailbox_id),
         %{} = sent <- Enum.find(folders, &(&1.kind == "sent")) do
      redirect(conn, to: ~p"/mail/#{mailbox_id}/folders/#{sent.id}")
    else
      _unavailable -> unavailable(conn)
    end
  end

  def show(conn, %{
        "mailbox_id" => mailbox_id_param,
        "outbound_message_id" => message_id_param
      }) do
    with {:ok, mailbox_id} <- Ecto.UUID.cast(mailbox_id_param),
         {:ok, message_id} <- Ecto.UUID.cast(message_id_param) do
      redirect(conn, to: ~p"/mail/#{mailbox_id}/send-activity/#{message_id}")
    else
      :error -> unavailable(conn)
    end
  end

  defp unavailable(conn) do
    conn
    |> put_flash(:error, "The requested mailbox view is unavailable.")
    |> redirect(to: ~p"/")
  end
end
```

- [ ] **Step 6: Separate MailLive assigns and navigation**

Rename `sent_items`/`sent_detail` and `:sent`/`:sent_detail` to `send_activity_items`/`send_activity_detail` and `:send_activity`/`:send_activity_detail`. Update queue success to navigate to the new detail URL.

Remove the hard-coded outbound `Sent` link. Let the existing generic folder loop render Sent once and add its icon:

```elixir
%{
  "inbox" => "inbox",
  "archive" => "archive",
  "sent" => "send-outline",
  "trash" => "trash-can-outline"
}
```

Add a separate hard-coded link labeled `Send activity` targeting `/send-activity`; its list/reader headings and ARIA labels also say Send activity. Preserve all outbound state labels and timeline content.

- [ ] **Step 7: Run route, LiveView, and outbound tests**

```sh
devenv shell -- mix test \
  apps/manifold_outbound/test/manifold/outbound_test.exs \
  apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs \
  apps/manifold_web/test/manifold_web/mail_live_test.exs \
  apps/manifold_web/test/manifold_web/sent_redirect_controller_test.exs
```

Expected: projected Sent and Send activity render distinct data, navigation contains one Sent label, queueing opens activity detail, and both legacy redirects preserve their intended target.

- [ ] **Step 8: Commit the Sent/Send activity split**

```sh
git add -- apps/manifold_outbound/lib/manifold/outbound.ex \
  apps/manifold_outbound/lib/manifold/outbound/view.ex \
  apps/manifold_outbound/test/manifold/outbound_test.exs \
  apps/manifold_web/lib/manifold_web/router.ex \
  apps/manifold_web/lib/manifold_web/controllers/sent_redirect_controller.ex \
  apps/manifold_web/lib/manifold_web/live/mail_live/index.ex \
  apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs \
  apps/manifold_web/test/manifold_web/mail_live_test.exs \
  apps/manifold_web/test/manifold_web/sent_redirect_controller_test.exs
git commit -m "feat(web): separate Sent from Send activity"
```

### Task 13: Complete lifecycle cleanup, safe observability, ADR, and operator docs

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth_authorizations.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/microsoft_folder_mapping.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/submission.ex`
- Modify: `apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/sync_test.exs`
- Modify: `apps/manifold_outbound/test/manifold/outbound/submission_test.exs`
- Modify: `apps/manifold_account_lifecycle/test/manifold/account_lifecycle/purge_test.exs`
- Create: `docs/adr/0011-microsoft-graph-send-and-authoritative-sent.md`
- Modify: `docs/adr/0007-read-only-provider-connectors.md`
- Modify: `docs/adr/0010-account-selected-outbound-methods.md`
- Modify: `docs/DESIGN.md`
- Modify: `README.md`
- Modify: `.agents/skills/develop/references/gmail-shared-authorizations.md`
- Modify: `.agents/skills/develop/references/microsoft-365-receive-send-methods.md`

- [ ] **Step 1: Write failing telemetry/activity redaction tests**

Attach handlers to:

```elixir
[:manifold, :connectors, :oauth, :start, :stop]
[:manifold, :connectors, :oauth, :complete, :stop]
[:manifold, :connectors, :oauth, :refresh, :stop]
[:manifold, :connectors, :microsoft, :folder_mapping, :stop]
[:manifold, :connectors, :sync, :stop]
[:manifold, :outbound, :send_method, :select, :stop]
[:manifold, :outbound, :submit, :stop]
```

Exercise connected, scope-upgraded, rejected, refreshed, reconnect-required, mapping-repaired, accepted, retryable, permanent, and uncertain outcomes. Assert measurements contain duration/attempt or changed-row counts and metadata contains only internal IDs, provider/method kind, outcome, and whitelisted normalized codes. Recursively inspect telemetry metadata, ConnectorEvent metadata, OutboundEvent metadata, activity-log lines, provider metadata, and Oban args and reject secret/body/address/subject/Bcc sentinels.

Remove `provider_message_id` and free-form `error_message` from Sync telemetry metadata; retain only internal account IDs, provider, result, and normalized error code. Provider message IDs stay in the connector database where replay identity requires them, not in telemetry.

- [ ] **Step 2: Add account lifecycle coverage**

Extend `purge_test.exs` with a target mailbox containing a shared Microsoft authorization, linked receive/send methods, encrypted tokens, cursors, remote mappings, ApplyRemoteState/SyncAccount/SubmitOutbound jobs, authorization events, an outbound payload, and projected Sent entries. After bounded purge completion, assert every target row/job/log/object is absent, another account's Microsoft authorization and Sent entry remain, and ciphertext/payload sentinels never appear in purge audit fields.

Also assert account deactivation blocks new OAuth completion, manual sync enqueue, queueing, and token checkout through existing active-account fences without deleting retained data.

- [ ] **Step 3: Run lifecycle and observability tests**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_account_lifecycle/test/manifold/account_lifecycle/purge_test.exs
```

Expected: FAIL for any missing provider-aware telemetry, unsafe metadata, or residual Microsoft authorization/payload data; pass after the narrow lifecycle/metadata corrections.

- [ ] **Step 4: Finalize safe events without adding message content**

Ensure the extracted OAuth engine uses the actual provider rather than a Gmail module attribute in event/telemetry metadata. Emit folder-mapping telemetry with:

```elixir
measurements: %{duration_ms: non_neg_integer, cursor_count: non_neg_integer,
  changed_message_count: non_neg_integer}
metadata: %{account_id: uuid, method_id: uuid, provider: "microsoft",
  outcome: :current | :repaired | :error, error_code: whitelisted_code_or_nil}
```

Reuse outbound's existing submit telemetry, which already distinguishes accepted/retryable/failed/uncertain, after adding `microsoft` as provider/method kind. Keep Graph response body and all message data out of every event.

- [ ] **Step 5: Write ADR 0011**

Record these decisions and consequences:

- the receive connector remains read-only (`Mail.Read`), while independently authorized outbound uses `Mail.Send`;
- direct MIME `/me/sendMail` avoids `Mail.ReadWrite` and draft reconciliation;
- exact queue-time MIME persistence is the retry identity boundary;
- bodyless 202 is acceptance, not delivery, and has no provider message ID;
- Graph Sent Items imported through normal delta is authoritative;
- projected Sent and outbound Send activity remain separate models;
- explicit 429/pre-dispatch failures retry, while 5xx/ambiguous transport is terminal uncertainty;
- no webhook, optimistic Sent copy, direct record link, or automatic uncertain resend is introduced.

- [ ] **Step 6: Update architecture and operator documentation**

In `docs/adr/0007-read-only-provider-connectors.md`, keep remote receive mutation read-only and document separately scoped outbound. In ADR 0010 and `docs/DESIGN.md`, document Microsoft in shared authorization, selected-method snapshotting, payload persistence, well-known ID mapping, Sent/Send activity split, and uncertainty.

Update `README.md` to remove the Microsoft receive-only claim and state:

```text
Microsoft delegated permissions: User.Read, Mail.Read, and Mail.Send.
Tenant default: organizations (work/school accounts only).
Callback: https://<host>/connectors/microsoft/callback.
Existing receive-only accounts grant Mail.Send incrementally when Send is added.
Provider acceptance is immediate in Send activity; the authoritative Sent copy
appears after normal/manual Graph polling when Receive is enabled.
Back up MANIFOLD_CONNECTOR_ENCRYPTION_KEY; changing it without a coordinated
rotation makes stored OAuth credentials unreadable.
```

Include staging registration/consent restrictions and clearly state that an absent complete client pair leaves Microsoft visible but unavailable, while a partial pair fails startup.

- [ ] **Step 7: Update repository feature references**

Keep the Microsoft feature reference status `in-progress` in this task, but replace design-stage ownership with the actual modules/migrations, migration/cursor/payload invariants, completed focused commands, external staging status, and any opened upstream issue. Task 14 changes the status to implemented only after the complete scoped verification matrix passes. Update the Gmail shared-authorization reference to say `OAuthAuthorizations` now serves Gmail and Microsoft while keeping provider-specific scopes/adapters.

- [ ] **Step 8: Run documentation and security-claim scans**

```sh
rg -n "Microsoft Graph remains receive-only" README.md docs/DESIGN.md docs/adr
rg -n "list_sent|get_sent|View\.Sent" apps
rg -n "Mail\.ReadWrite|/common/|/consumers/" \
  apps config README.md docs/adr/0011-microsoft-graph-send-and-authoritative-sent.md
rg -n "access_token|refresh_token|authorization_code|request_payload|raw_message" \
  apps/manifold_outbound/lib apps/manifold_connectors/lib
```

Expected: first scan has no stale production claim/API; second has no runtime request for excluded permissions/tenants (the ADR may mention them only as rejected choices); third shows secrets/payload only in encryption, schema, redaction, and short-lived provider boundary code, never job args or metadata construction.

- [ ] **Step 9: Run lifecycle/telemetry tests again**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_account_lifecycle/test/manifold/account_lifecycle/purge_test.exs
```

Expected: all pass with redaction and purge assertions.

- [ ] **Step 10: Commit lifecycle, telemetry, and docs**

```sh
git add -- apps/manifold_connectors/lib/manifold/connectors/oauth_authorizations.ex \
  apps/manifold_connectors/lib/manifold/connectors/microsoft_folder_mapping.ex \
  apps/manifold_connectors/lib/manifold/connectors/sync.ex \
  apps/manifold_outbound/lib/manifold/outbound/submission.ex \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_account_lifecycle/test/manifold/account_lifecycle/purge_test.exs \
  docs/adr/0011-microsoft-graph-send-and-authoritative-sent.md \
  docs/adr/0007-read-only-provider-connectors.md \
  docs/adr/0010-account-selected-outbound-methods.md docs/DESIGN.md README.md \
  .agents/skills/develop/references/gmail-shared-authorizations.md \
  .agents/skills/develop/references/microsoft-365-receive-send-methods.md
git commit -m "docs(connectors): document Microsoft mail delivery"
```

### Task 14: Run scoped regression, migration rehearsal, and staging verification

**Files:**
- Modify only in-scope files from Tasks 1-13 if verification exposes an in-scope defect.

- [ ] **Step 1: Format every changed Elixir file**

```sh
changed_ex=$(git diff --name-only main...HEAD -- '*.ex' '*.exs')
if [ -n "$changed_ex" ]; then
  devenv shell -- mix format $changed_ex
fi
devenv shell -- mix format --check-formatted
```

Expected: exit 0. If `mix format` changes a file, inspect that diff before staging.

- [ ] **Step 2: Compile strictly**

```sh
devenv shell -- mix compile --warnings-as-errors
```

Expected: exit 0 with no warnings, undefined optional callbacks, stale Gmail module references, or unmatched LiveView actions.

- [ ] **Step 3: Run every scoped application suite**

```sh
devenv shell -- mix test apps/manifold_mail/test
devenv shell -- mix test apps/manifold_connectors/test
devenv shell -- mix test apps/manifold_outbound/test
devenv shell -- mix test apps/manifold_web/test
devenv shell -- mix test apps/manifold_account_lifecycle/test
devenv shell -- mix test apps/manifold_data/test
```

Expected: all in-scope suites pass. JavaScript was not changed, so `mix duskmoon_bundler.js.check` is not required; run it only if the implementation introduces a JavaScript change.

- [ ] **Step 4: Rehearse clean migration up/down/up**

Against the explicitly named disposable database `manifold_ms_delivery_test`, migrate through `20260811000700`, migrate the three `20260812` migrations, roll them back on empty feature tables, and migrate forward again:

```sh
devenv shell -- env -u TEST_DATABASE_URL POSTGRES_TEST_DB=manifold_ms_delivery_test MIX_ENV=test mix ecto.create
devenv shell -- env -u TEST_DATABASE_URL POSTGRES_TEST_DB=manifold_ms_delivery_test MIX_ENV=test mix ecto.migrate --to 20260811000700
devenv shell -- env -u TEST_DATABASE_URL POSTGRES_TEST_DB=manifold_ms_delivery_test MIX_ENV=test mix ecto.migrate
devenv shell -- env -u TEST_DATABASE_URL POSTGRES_TEST_DB=manifold_ms_delivery_test MIX_ENV=test mix ecto.rollback --step 3
devenv shell -- env -u TEST_DATABASE_URL POSTGRES_TEST_DB=manifold_ms_delivery_test MIX_ENV=test mix ecto.migrate
```

Expected: all commands exit 0 in the isolated database and the schema ends at the latest migration.

- [ ] **Step 5: Rehearse upgrade with realistic legacy data**

At migration `20260811000700`, insert fixtures for:

- two Microsoft receive methods for two distinct mailboxes with encrypted legacy tokens;
- localized folder/message cursors, remote mappings, imported history, and queued sync jobs;
- a custom folder named Sent containing a projected entry;
- Gmail authorization/receive/send rows;
- IMAP/EAS/SMTP rows;
- queued Gmail/SMTP rows without immutable payloads;
- queued Resend work.

Migrate forward and verify:

```text
Microsoft auth ID equals legacy receive ID and tokens still decrypt.
Receive status/enabled state, cursors, remote mappings, history, and jobs are unchanged.
Events are authorization-anchored.
Custom Sent and its entry are preserved under the deterministic renamed folder.
Every mailbox has one system Sent.
Gmail/IMAP/EAS/SMTP and queued Resend rows are unchanged.
Legacy Gmail/SMTP submissions gain payload only on first verified attempt.
No migration performs a network request.
```

Then run one upgraded Microsoft sync and prove mapping repair changes only metadata/remote placement, not cursor URLs or raw fetch count.

After capturing the rehearsal evidence, remove only the explicitly named disposable database:

```sh
devenv shell -- env -u TEST_DATABASE_URL POSTGRES_TEST_DB=manifold_ms_delivery_test MIX_ENV=test mix ecto.drop
```

Expected: `manifold_ms_delivery_test` is dropped; the normal `manifold_test` and development databases are untouched.

- [ ] **Step 6: Verify all thirteen acceptance criteria explicitly**

Record pass/fail evidence in the feature reference for this matrix:

```text
1. Legacy Microsoft receive continues without reauthorization/cursor reset.
2. Localized folders classify and repair by well-known ID.
3. Every mailbox has exactly one usable Sent.
4. Receive-only adds Mail.Send without Mail.ReadWrite.
5. Distinct identities isolate; subject/address mismatch rejects.
6. Queue snapshot selects Microsoft and never implicit Resend.
7. Exact MIME reaches /me/sendMail; bodyless 202 accepts without delivery claim.
8. Only 429/proven pre-dispatch retries; ambiguous outcomes never resend.
9. Authoritative Sent item imports once only when Receive exists.
10. Projected Sent and Send activity are separate with compatible old URLs.
11. Revocation pauses both; one-direction disconnect preserves the other.
12. Secrets and message data are absent from logs/telemetry/metadata/jobs.
13. Scoped tests, formatting, and strict compilation pass.
```

When all thirteen rows pass, update `.agents/skills/develop/references/microsoft-365-receive-send-methods.md` from `in-progress` to `implemented`, record the exact command results, and retain `external staging not run: credentials unavailable` when Step 7 cannot run.

- [ ] **Step 7: Run credentialed staging smoke test when secrets are available**

1. Register the exact HTTPS callback and delegated `User.Read`, `Mail.Read`, and `Mail.Send` for tenant `organizations`.
2. Connect two matching non-production Microsoft 365 identities to two distinct accounts.
3. Receive new/moved/deleted messages with localized folder names and verify account isolation/raw projection.
4. Incrementally add Microsoft Send to both accounts.
5. Send plain-text messages with To, Cc, Bcc, subject, UTF-8 body, and reply headers.
6. Confirm each Send activity detail becomes accepted immediately with request correlation but no provider message ID.
7. Trigger or await normal delta sync and confirm each provider Sent copy appears exactly once in its local Sent folder.
8. Revoke one grant and confirm both directions pause only for that account and one reconnect action restores them.
9. Inspect logs, activity files, telemetry, provider metadata, and Oban args for all staged secret/message sentinels.

If credentials are unavailable, record `external staging not run: credentials unavailable` in the feature reference; do not report a pass.

- [ ] **Step 8: Inspect final scope and history**

```sh
git status --short
git diff --check
git diff main...HEAD --stat
git log --oneline main..HEAD
```

Expected: only files listed in this plan changed; no unrelated worktree file is staged; task-sized conventional commits tell the implementation sequence.

- [ ] **Step 9: Commit verification-only corrections when present**

If scoped verification changed files, stage only the file paths reported by `git status --short`, inspect `git diff --cached`, and commit:

```sh
git commit -m "test: verify Microsoft mail delivery"
```

If verification changed nothing, do not create an empty commit.

## Completion evidence

The implementation is complete only when Tasks 1-14 are checked, the acceptance matrix is recorded in `.agents/skills/develop/references/microsoft-365-receive-send-methods.md`, every available scoped check passes, and unavailable credentialed staging is explicitly recorded rather than inferred. Stop after that point; HTML/attachments, Outlook.com, aliases/delegation, webhooks, remote mailbox mutation, optimistic Sent, automatic uncertain resend, and direct outbound-to-Sent linkage remain outside this feature.
